# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

module Unikraft
  module Cloud
    # Raised for every failure the SDK reports. A single class (with
    # subclasses for the multi-metro cases) so one `rescue` covers both APIs.
    #
    # `kind` says what went wrong:
    # - `:http`: the server answered with a non-2xx status;
    # - `:network`: the request never got an answer (refused, reset, DNS, TLS,
    #   read timeout);
    # - `:parse`: a 2xx answer whose body is not the JSON it should be;
    # - `:fanout`: a multi-metro operation failed in some metros, or a ref is
    #   ambiguous across metros;
    # - `:config`: a call that could never be sent as configured (no token,
    #   contradicting options, a body on a GET);
    # - `:timeout`: a wait ran out of time. It carries no `status`, because no
    #   single request failed; the last failure is the `cause`.
    class Error < StandardError
      KINDS = %i[http network parse fanout config timeout].freeze

      # @return [Symbol] one of {KINDS}
      attr_reader :kind
      # @return [Integer, nil] the HTTP status code, when there was one
      attr_reader :status
      # @return [Array<Hash>, nil] the `errors` of the response envelope
      attr_reader :errors
      # @return [Object, nil] the parsed response body, or the raw text
      attr_reader :body

      # @param message [String]
      # @param kind [Symbol] one of {KINDS}
      # @param status [Integer, nil]
      # @param errors [Array<Hash>, nil]
      # @param body [Object, nil]
      # @param cause [Exception, nil] overrides Ruby's implicit `cause`
      def initialize(message = nil, kind:, status: nil, errors: nil, body: nil, cause: nil)
        raise ArgumentError, "unknown error kind #{kind.inspect}" unless KINDS.include?(kind)

        super(message)
        @kind = kind
        @status = status
        @errors = errors
        @body = body
        @cause = cause
      end

      # The underlying failure: the one given explicitly, or else the
      # exception being handled when this one was raised.
      def cause
        @cause || super
      end
    end

    # Raised when a name matches in more than one metro and the operation can
    # act on only one. Names are unique within a metro, not across them, so
    # this is routine: qualify the ref with a metro, narrow the scope, or act
    # on every match. The matches are attached, so recovering costs nothing.
    class AmbiguousRefError < Error
      # @return [Array] the matching resources, each tagged with its `metro`
      attr_reader :matches

      def initialize(message, matches:)
        super(message, kind: :fanout, body: matches)
        @matches = matches
      end

      # @return [Array<String>] the metros the name was found in
      def metros
        matches.map(&:metro)
      end
    end

    # Raised when an operation fanned out over several metros failed in some
    # of them. `failures` holds `{metro:, error:}` entries in the order they
    # occurred; `results` holds whatever the other metros returned.
    class MetroFanoutError < Error
      # @return [Array<Hash>] `{metro:, error:}` per failed metro
      attr_reader :failures
      # @return [Array] the results of the metros that succeeded
      attr_reader :results

      def initialize(message, failures:, results: [])
        statuses = failures.map { |f| f[:error].respond_to?(:status) ? f[:error].status : nil }.uniq
        # A single underlying status is surfaced, so `status == 403` still matches.
        super(message, kind: :fanout, status: statuses.size == 1 ? statuses.first : nil,
                       body: failures, cause: failures.first&.dig(:error))
        @failures = failures
        @results = results
      end
    end
  end
end
