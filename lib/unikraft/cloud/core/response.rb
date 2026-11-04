# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require_relative "errors"

module Unikraft
  module Cloud
    module Core
      # Unwrapping the response envelope the plumbing returns.
      module Response
        # The platform's per-entry `error` codes the SDK acts on, as the HTTP
        # status that says the same. Code 8 is "no such resource", answered
        # with HTTP 200; the spec publishes no list, so this records observed
        # behaviour. {absent} depends on it.
        ENTRY_ERROR_STATUS = { 8 => 404 }.freeze

        module_function

        # The envelope's `data`, after checking it reports no failure.
        #
        # A whole-request failure fills the top-level `errors`; a per-resource
        # one marks its entry inside `data` with `status: "error"`, which
        # then supplies the message and status. A `partial_success` whose
        # failures stay inside `data` is returned as is: the caller asked for
        # several resources and the successes are in the same list.
        #
        # @param res [Model, nil] the envelope
        # @return [Model, nil]
        # @raise [Unikraft::Cloud::Error] kind `:http`
        def unwrap(res)
          return nil if res.nil?

          reported = Array(res[:errors]).first
          return res[:data] if res[:status] != "error" && reported.nil?

          raise failure(res, reported.nil? ? first_failure(res[:data]) : nil, reported&.[](:status))
        end

        # The `data[key]` list of an envelope (empty when absent).
        #
        # @return [Array<Model>]
        def list(res, key)
          Array(unwrap(res)&.[](key))
        end

        # The first entry of `data[key]`. A single-resource caller has no
        # use for a failed entry, so any failed one in a `partial_success`
        # (e.g. one property of an update) raises.
        #
        # @param what [String] the subject of the not-found message
        # @raise [Unikraft::Cloud::Error] status 404 when the list is empty
        def first(res, key, what)
          entries = list(res, key)
          if entries.empty?
            raise Error.new("#{what} not found", kind: :http, status: 404, body: res)
          end

          failed = entries.find { |entry| entry[:status] == "error" }
          raise failure(res, failed) if failed

          entries.first
        end

        # The block's value, or nil when it reports the resource absent (404).
        # Searching several metros means most legitimately answer "not here".
        def absent
          yield
        rescue Error => e
          raise unless e.status == 404

          nil
        end

        def failure(res, entry, status = nil)
          status ||= ENTRY_ERROR_STATUS[entry&.[](:error)]
          message = entry&.[](:message) || res[:message] || "Unikraft Cloud API reported an error"
          Error.new(message, kind: :http, status:, errors: res.to_h[:errors], body: res)
        end
        private_class_method :failure

        def first_failure(data)
          data.to_h.each_value do |value|
            next unless value.is_a?(Array)

            hit = value.find { |entry| entry.is_a?(Hash) && entry[:status] == "error" }
            return hit if hit
          end
          nil
        end
        private_class_method :first_failure
      end
    end
  end
end
