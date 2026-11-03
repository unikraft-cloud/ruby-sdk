# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# Asking a service repeatedly whether it is ready yet.
#
# This module owns the mechanism only: the backoff, the deadline and, most
# importantly, which failures are worth asking again about. What to ask, and
# what to say when the answer never comes, belong to the caller.

require_relative "errors"

module Unikraft
  module Cloud
    module Core
      # Polling with capped, jittered exponential backoff and a deadline.
      module Ready
        # The values {wait_until_ready} uses for anything left out, in seconds.
        DEFAULTS = { initial_delay: 0.1, max_delay: 2.0, timeout: 60.0 }.freeze

        # The HTTP statuses worth probing again for. 502/503/504 are a proxy
        # with nothing to forward to yet; 404 is a plugin route not registered
        # yet while the instance boots. Everything else is final, and 401/403
        # especially so: retrying a rejected token would turn "unauthorized"
        # into a timeout and hide the one error the caller can act on.
        RETRYABLE_STATUSES = [404, 502, 503, 504].freeze

        module_function

        # Whether a failed probe says "not yet" rather than "no".
        #
        # @param err [Exception]
        # @return [Boolean]
        def retryable?(err)
          return false unless err.is_a?(Unikraft::Cloud::Error)
          # A refused connection, a reset, a DNS miss: still coming up.
          return true if err.kind == :network

          err.kind == :http && RETRYABLE_STATUSES.include?(err.status)
        end

        # Probe until it succeeds, and return once it does.
        #
        # The block is the probe. It should be cheap, idempotent, and answer as
        # soon as the service is usable. It is given the seconds left until the
        # deadline, and should pass them on as the request's `timeout:`, since
        # a probe in flight is not interrupted.
        #
        # @param initial_delay [Numeric] first delay between probes (0.1 s)
        # @param max_delay [Numeric] cap on the delay between probes (2 s)
        # @param timeout [Numeric] give up after this long (60 s)
        # @param what [String] the subject of the timeout message
        # @param diagnose [#call, nil] asked once, only after the deadline, with
        #   the last error; returns a phrase naming the real cause, appended to
        #   the timeout message
        # @yieldparam remaining [Float] seconds left until the deadline
        # @return [nil]
        # @raise [Unikraft::Cloud::Error] kind `:timeout` when the deadline
        #   passes, with the last probe failure as `cause`; or the probe's own
        #   error when it is not retryable
        # @raise [ArgumentError] when a duration is not a usable number
        #
        # @example
        #   Ready.wait_until_ready(timeout: 10, what: "sandbox #{uuid}") do |left|
        #     api.list_commands(timeout: left)
        #   end
        def wait_until_ready(initial_delay: DEFAULTS[:initial_delay],
                             max_delay: DEFAULTS[:max_delay], timeout: DEFAULTS[:timeout],
                             what: "the service", diagnose: nil)
          delay = duration(:initial_delay, initial_delay, zero: false)
          max_delay = duration(:max_delay, max_delay, zero: false)
          timeout = duration(:timeout, timeout, zero: true)
          deadline = now + timeout
          attempts = 0
          last_error = nil

          loop do
            attempts += 1
            begin
              yield [deadline - now, 0.0].max
              return nil
            rescue Unikraft::Cloud::Error => e
              raise unless retryable?(e)

              last_error = e
            end

            delay = back_off(delay, max_delay, deadline - now)
            next if now < deadline

            raise timed_out(what, timeout, attempts, last_error, diagnose)
          end
        end

        # Sleep before the next probe, never past the deadline, and return the
        # next delay. Jitter covers the lower half of the window, so a fleet
        # created together does not probe in lockstep.
        def back_off(delay, max_delay, remaining)
          return delay unless remaining.positive?

          window = [delay, max_delay].min
          sleep([(window / 2.0) + (rand * window / 2.0), remaining].min)
          [delay * 2, max_delay].min
        end

        def timed_out(what, timeout, attempts, last_error, diagnose)
          why = begin
            diagnose&.call(last_error)
          rescue StandardError
            nil # A failed diagnosis must not replace the timeout it explains.
          end
          last = if last_error
                   "The last attempt failed with: #{last_error.message}"
                 else
                   "The last probe never answered."
                 end
          # No `status`: the deadline failed, not one request. Carrying the last
          # probe's 404 would make this look like a missing resource.
          Unikraft::Cloud::Error.new(
            "#{what} was not ready within #{timeout} s (#{attempts} " \
            "#{attempts == 1 ? "probe" : "probes"})#{": #{why}" if why}. #{last}",
            kind: :timeout, cause: last_error
          )
        end

        # A value the loop cannot use (NaN, negative) would poll flat out
        # instead of waiting, so it is refused rather than clamped.
        def duration(name, value, zero:)
          ok = value.is_a?(Numeric) && value.to_f.finite? && (zero ? value >= 0 : value.positive?)
          return value.to_f if ok

          raise ArgumentError, "`#{name}` must be a number of seconds, " \
                               "#{zero ? "0 or more" : "above 0"}. Received #{value.inspect}."
        end

        def now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        private_class_method :back_off, :timed_out, :duration, :now
      end
    end
  end
end
