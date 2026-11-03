# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# Shared, spec-independent HTTP transport for the generated plumbing clients
# and the plugin gems.

require "json"
require "net/http"
require "openssl"
require "uri"

require_relative "errors"
require_relative "url"
require_relative "../version"

module Unikraft
  module Cloud
    module Core
      # Transport for one base URL. Performs authenticated requests and
      # returns the parsed response envelope. Raises {Unikraft::Cloud::Error}
      # on network failures and non-2xx responses. It never retries.
      #
      # It satisfies the duck-typed transport the plugin gems
      # (`unikraft-cloud-plugin-<name>-api`) take: `request`, `bytes` and
      # `stream`, each with the keywords `method:`, `path:`, `query:`,
      # `body:`, `headers:`, plus the per-call `base_url:` and `timeout:`.
      # A change to one of those signatures is a breaking change for every
      # plugin gem; see CONTRIBUTING.md, "The transport contract".
      #
      # Proxies come from the environment (`http_proxy`, `https_proxy`,
      # `no_proxy`, any case) through Net::HTTP, unless `proxy_from_env:` is
      # false.
      #
      # @example
      #   client = Unikraft::Cloud::Core::ApiClient.new(
      #     base_url: "https://api.fra.unikraft.cloud", token: ENV["UKC_TOKEN"]
      #   )
      #   client.request(method: :get, path: "/v1/instances", query: { count: 10 })
      class ApiClient
        # Seconds to wait for a connection and for each read, by default.
        DEFAULT_TIMEOUT = 60

        # Methods that must not carry a body.
        BODYLESS = %w[GET HEAD].freeze

        # Separator between two server-sent events.
        SSE_EVENT_BOUNDARY = /\r\n\r\n|\n\n|\r\r/

        # What Net::HTTP raises when a request never gets an answer.
        NETWORK_ERRORS = [
          IOError, SocketError, SystemCallError, Timeout::Error,
          OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
        ].freeze

        # @return [String] the base URL, without trailing slashes
        attr_reader :base_url
        # @return [String, nil] the bearer token
        attr_reader :token
        # @return [Hash{String => String}] headers sent with every request
        attr_reader :headers
        # @return [Numeric, nil] the default timeout in seconds
        attr_reader :timeout

        # @param base_url [String] e.g. `https://api.fra.unikraft.cloud`
        # @param token [String, nil] bearer token
        # @param headers [Hash{String => String}] default headers
        # @param user_agent [String, nil] overrides the SDK's User-Agent
        # @param timeout [Numeric, nil] seconds per connect and read; nil
        #   waits without limit
        # @param proxy_from_env [Boolean] honour the proxy env variables
        def initialize(base_url:, token: nil, headers: {}, user_agent: nil,
                       timeout: DEFAULT_TIMEOUT, proxy_from_env: true)
          @base_url = URL.strip_trailing_slashes(base_url)
          @token = token
          @headers = { "User-Agent" => user_agent || "unikraft-cloud-ruby/#{VERSION}" }
          headers&.each { |k, v| @headers[k.to_s] = v.to_s }
          @timeout = timeout
          @proxy_from_env = proxy_from_env
        end

        # Perform a request and return its parsed JSON body (symbol keys).
        #
        # @param method [String, Symbol] HTTP method
        # @param path [String] path below the base URL, already escaped
        # @param query [Hash, nil] query parameters; arrays repeat the key and
        #   nil values are left out
        # @param body [Object, nil] JSON body; refused on GET and HEAD
        # @param headers [Hash, nil] merged over the defaults for this call
        # @param options [Hash] `base_url:` and `timeout:` for this call
        # @return [Hash, Array, nil] the parsed body, or nil when empty
        # @raise [Unikraft::Cloud::Error]
        def request(method:, path:, query: nil, body: nil, headers: nil, **options)
          perform("application/json", method:, path:, query:, body:, headers:,
                                      **options) do |res, url|
            text = res.body.to_s
            parsed = text.empty? ? nil : parse_json(text, res, url)
            raise http_error(res, parsed, text) unless res.is_a?(Net::HTTPSuccess)

            parsed
          end
        end

        # Perform a request whose success response is an unenveloped
        # `application/octet-stream` body, and return it verbatim.
        #
        # @param (see #request)
        # @return [String] the body, binary
        # @raise [Unikraft::Cloud::Error]
        def bytes(method:, path:, query: nil, body: nil, headers: nil, **options)
          perform("application/octet-stream", method:, path:, query:, body:, headers:,
                                              **options) do |res, _|
            raise http_error(res, *lenient_json(res.body.to_s)) unless res.is_a?(Net::HTTPSuccess)

            res.body.to_s.b
          end
        end

        # Perform a request whose response is a `text/event-stream`, and yield
        # each event's JSON payload (symbol keys) as it arrives. Returns when
        # the server closes the stream; `break` out of the block to stop early
        # and release the connection.
        #
        # @param (see #request)
        # @yieldparam event [Hash, Array] one event's parsed `data`
        # @return [Enumerator, nil] an Enumerator when no block is given
        # @raise [Unikraft::Cloud::Error]
        def stream(method:, path:, query: nil, body: nil, headers: nil, **options, &block)
          unless block
            return enum_for(:stream, method: method, path: path, query: query, body: body,
                                     headers: headers, **options)
          end

          perform("text/event-stream", method:, path:, query:, body:, headers:,
                                       **options) do |res, url|
            raise http_error(res, *lenient_json(res.body.to_s)) unless res.is_a?(Net::HTTPSuccess)

            read_events(res, url, &block)
          end
          nil
        end

        private

        # Build and send one request, and hand the response to the block while
        # the connection is open (so a stream can be read from it).
        def perform(accept, method:, path:, query:, body:, headers:, **options)
          options = call_options(options)
          verb = method.to_s.upcase
          if !body.nil? && BODYLESS.include?(verb)
            raise Error.new("A #{verb} request cannot carry a body; pass the filters as query " \
                            "parameters instead", kind: :config)
          end

          url = URL.strip_trailing_slashes(options.fetch(:base_url) || @base_url) +
                path.to_s + encode_query(query)
          uri = URI(url)
          req = build_request(verb, uri, body, headers, accept)
          via_proxy = false
          begin
            http = connection(uri, options.fetch(:timeout))
            via_proxy = http.proxy?
            http.start do
              http.request(req) do |res|
                return yield(res, url) if accept == "text/event-stream"

                res.read_body
                return yield(res, url)
              end
            end
          rescue *NETWORK_ERRORS => e
            raise network_error(url, e, via_proxy)
          end
        end

        def call_options(options)
          unknown = options.keys - %i[base_url timeout]
          raise ArgumentError, "unknown keyword(s): #{unknown.join(", ")}" unless unknown.empty?

          { base_url: options[:base_url], timeout: options.fetch(:timeout, @timeout) }
        end

        def build_request(verb, uri, body, headers, accept)
          req = Net::HTTPGenericRequest.new(verb, !body.nil?, verb != "HEAD", uri)
          req["Accept"] = accept
          @headers.each { |k, v| req[k] = v }
          req["Authorization"] = "Bearer #{@token}" if @token
          headers&.each { |k, v| req[k.to_s] = v.to_s }
          unless body.nil?
            req["Content-Type"] = "application/json"
            req.body = JSON.generate(body)
          end
          req
        end

        def connection(uri, timeout)
          proxy = @proxy_from_env ? :ENV : nil
          http = Net::HTTP.new(uri.host, uri.port, proxy)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = timeout
          http.read_timeout = timeout
          http.write_timeout = timeout
          http
        end

        # Serialise a query hash in form/explode style.
        def encode_query(query)
          return "" if query.nil?

          pairs = query.each_with_object([]) do |(key, value), out|
            next if value.nil?

            Array(value).each { |item| out << [key.to_s, item.to_s] unless item.nil? }
          end
          pairs.empty? ? "" : "?#{URI.encode_www_form(pairs)}"
        end

        def parse_json(text, res, url)
          JSON.parse(text, symbolize_names: true)
        rescue JSON::ParserError => e
          unless res.is_a?(Net::HTTPSuccess)
            raise Error.new("HTTP #{res.code} #{res.message}".strip,
                            kind: :http, status: res.code.to_i, body: text, cause: e)
          end

          raise Error.new("Failed to parse response body from #{url}",
                          kind: :parse, status: res.code.to_i, body: text, cause: e)
        end

        # Decode an error body that may or may not be an envelope.
        def lenient_json(text)
          parsed = text.empty? ? nil : JSON.parse(text, symbolize_names: true)
          [parsed, text]
        rescue JSON::ParserError
          [nil, text]
        end

        def http_error(res, parsed, text)
          envelope = parsed.is_a?(Hash) ? parsed : {}
          message = envelope[:message] || "HTTP #{res.code} #{res.message}".strip
          Error.new(message, kind: :http, status: res.code.to_i,
                             errors: envelope[:errors], body: parsed.nil? ? text : parsed)
        end

        def network_error(url, cause, via_proxy)
          via = via_proxy ? " (through the proxy set in http_proxy/https_proxy)" : ""
          Error.new("Request to #{url} failed#{via}: #{cause.class}: #{cause.message}",
                    kind: :network, cause: cause)
        end

        def read_events(res, url)
          buffer = +""
          res.read_body do |chunk|
            buffer << chunk.b
            while (boundary = SSE_EVENT_BOUNDARY.match(buffer))
              block = buffer[0, boundary.begin(0)]
              buffer = buffer[boundary.end(0)..]
              event = parse_event(block, url, res)
              yield event unless event.nil?
            end
          end
          # A last event may arrive without its trailing blank line.
          event = parse_event(buffer, url, res)
          yield event unless event.nil?
        end

        # The JSON payload of one event block: its `data:` lines joined. Nil
        # for comments and keep-alives.
        def parse_event(block, url, res)
          values = block.dup.force_encoding(Encoding::UTF_8).split("\n").filter_map do |raw|
            line = raw.chomp("\r")
            next if line.start_with?(":")

            field, sep, value = line.partition(":")
            next unless field == "data"

            sep.empty? ? "" : value.delete_prefix(" ")
          end
          data = values.join("\n")
          return nil if data.empty?

          JSON.parse(data, symbolize_names: true)
        rescue JSON::ParserError => e
          raise Error.new("Failed to parse event stream from #{url}",
                          kind: :parse, status: res.code.to_i, body: data, cause: e)
        end
      end
    end
  end
end
