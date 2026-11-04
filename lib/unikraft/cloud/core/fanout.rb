# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# Running one operation across several metros and sewing the results back
# together. The platform API is metro-scoped, so an account-wide view means
# asking every metro and merging what comes back.

require_relative "errors"

module Unikraft
  module Cloud
    module Core
      # Concurrent per-metro work on threads.
      module Fanout
        # One item's outcome from {settled}.
        Outcome = Data.define(:item, :value, :error) do
          def ok? = error.nil?
        end

        module_function

        # Run `producer` for every endpoint concurrently and push each item it
        # emits onto `out` as soon as it arrives, so a slow metro never holds
        # up a fast one. Every healthy metro is drained first, then one
        # {MetroFanoutError} names the failures. A single endpoint runs
        # inline, and its failure propagates as itself. Only an {Error} is a
        # metro failure: anything else (a bug, an interrupt) is re-raised.
        #
        # The queue holds about one item per metro, so a producer fetches
        # its next page only once the consumer has nearly used up the last.
        # Leaving early (`break`, `first`) kills the metros still in flight.
        # An external enumerator (`Enumerator#next`) abandoned midway never
        # leaves, so its producers stay parked on the full queue, sending
        # nothing, until the process exits: prefer `each`, `first` or `lazy`.
        #
        # @param endpoints [Array<Endpoint>]
        # @param out [#<<] e.g. an Enumerator::Yielder
        # @yieldparam endpoint [Endpoint]
        # @yieldparam emit [Proc] call with each item
        def merge(endpoints, out)
          return yield(endpoints.first, ->(item) { out << item }) if endpoints.size == 1

          queue = SizedQueue.new(endpoints.size)
          threads = endpoints.map do |endpoint|
            Thread.new do
              error = nil
              yield endpoint, ->(item) { queue << [:item, item] }
            rescue Exception => e # rubocop:disable Lint/RescueException
              error = e # handed to the consumer, which re-raises what is not an Error
            ensure
              # Always report, or the consumer waits forever. A killed
              # producer (the consumer left, or the process is exiting) has
              # no one to report to, and could block on the full queue.
              begin
                queue << [:finished, endpoint, error] unless Thread.current.status == "aborting"
              rescue ClosedQueueError
                nil
              end
            end
          end
          drain(queue, out, endpoints.size)
        ensure
          queue&.close # wakes producers blocked on a full queue
          threads&.each(&:kill)
        end

        def drain(queue, out, total)
          failures = []
          pending = total
          while pending.positive?
            kind, value, error = queue.pop
            next out << value if kind == :item

            pending -= 1
            next if error.nil?
            raise error unless error.is_a?(Error)

            failures << { metro: value.metro, error: }
          end
          raise error(total, failures) unless failures.empty?
        end
        private_class_method :drain

        # Run the block for every item (anything with a `metro`) concurrently
        # and report every outcome, successes and failures alike. A failure
        # is an {Error}; any other exception propagates.
        #
        # @return [Array<Outcome>] in the order of `items`
        def settled(items)
          run = lambda do |item|
            Outcome.new(item:, value: yield(item), error: nil)
          rescue Error => e
            Outcome.new(item:, value: nil, error: e)
          end
          return items.map(&run) if items.size < 2

          # Collected as they finish, so a bug (anything but an Error) in one
          # surfaces at once, even while another is still blocked.
          done = Queue.new
          threads = items.each_with_index.map do |item, i|
            Thread.new do
              done << [i, run.call(item), nil]
            rescue Exception => e # rubocop:disable Lint/RescueException
              done << [i, nil, e]
            end
          end
          items.size.times.with_object(Array.new(items.size)) do |_, outcomes|
            i, outcome, error = done.pop
            raise error if error

            outcomes[i] = outcome
          end
        ensure
          # One raised: stop the rest, or they go on sending after the caller left.
          threads&.each(&:kill)
        end

        # Run the block for every item concurrently and return the values.
        # When some fail, raise a {MetroFanoutError} carrying the successes as
        # `results`.
        #
        # @param flat [Boolean] each value is an Array to concatenate
        # @return [Array]
        def all(items, flat: false, &)
          outcomes = settled(items, &)
          results = outcomes.select(&:ok?).map(&:value)
          results = results.flatten(1) if flat
          failures = outcomes.reject(&:ok?).map { |o| { metro: o.item.metro, error: o.error } }
          raise error(items.size, failures, results:) unless failures.empty?

          results
        end

        # The aggregate error, e.g. `1 of 3 metros failed: sin (503)`.
        #
        # @return [MetroFanoutError]
        def error(attempted, failures, results: [])
          detail = failures.map do |f|
            status = f[:error].respond_to?(:status) ? f[:error].status : nil
            status ? "#{f[:metro]} (#{status})" : f[:metro]
          end
          message = "#{failures.size} of #{attempted} metros failed: #{detail.join(", ")}"
          MetroFanoutError.new(message, failures:, results:)
        end
      end
    end
  end
end
