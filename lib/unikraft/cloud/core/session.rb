# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# The transport and metro knowledge shared by every resource client: one set
# of credentials, one memoised metro discovery, and the rules for turning a
# metro scope into concrete endpoints.

require_relative "errors"
require_relative "http"
require_relative "metro"
require_relative "response"
require_relative "../api"

module Unikraft
  module Cloud
    module Core
      # Shared state behind one client. Scoped clients (`ukc.metro(:fra)`)
      # reuse the same session, so discovery and transports are shared rather
      # than duplicated. Safe to share across threads: discovery and the
      # transport cache are guarded by a Mutex.
      class Session
        # @return [Endpoint] the endpoint of operations that must pick one
        #   metro, such as `create`
        attr_reader :default_endpoint
        # @return [Endpoint, nil] the only endpoint there is, when the caller
        #   named a URL
        attr_reader :pinned

        # @param config [Hash] {ApiClient#initialize} keywords other than
        #   `base_url:` (token, headers, timeout, ...)
        # @param platform_url [String] the default metro's base URL
        # @param controlplane_url [String]
        # @param default_metro [String]
        # @param pinned [Boolean] `platform_url` was named explicitly: never
        #   discover, never invent hostnames
        # @param transport [#call, nil] builds a transport from the
        #   {ApiClient} keywords; defaults to `ApiClient.new`
        def initialize(config:, platform_url:, controlplane_url:, default_metro:,
                       pinned: false, transport: nil)
          @config = config
          @build = transport || ->(**kw) { ApiClient.new(**kw) }
          @platform_url = platform_url
          @controlplane_url = controlplane_url
          @pinned = Endpoint.new(metro: platform_url, base_url: platform_url) if pinned
          @default_endpoint = @pinned || Endpoint.new(metro: default_metro, base_url: platform_url)
          @mutex = Mutex.new
          @discovery = Mutex.new
          @transports = {}
          @discovered = nil
        end

        # The transport for a base URL, built once and shared.
        #
        # @param base_url [String]
        # @return [#request, #bytes, #stream]
        def transport(base_url = @platform_url)
          @mutex.synchronize { @transports[base_url] ||= @build.call(base_url:, **@config) }
        end

        # Both raw API surfaces, the platform one pointing at `base_url`.
        #
        # @return [API]
        def api(base_url = @platform_url)
          API.new(platform: transport(base_url), controlplane: transport(@controlplane_url))
        end

        # Every metro the account can reach, asked of the control plane once
        # and cached. A failed discovery is not cached, so a transient outage
        # does not poison the client.
        #
        # @return [Array<Endpoint>]
        # @raise [Unikraft::Cloud::Error] kind `:fanout`
        def discover
          return [@pinned] if @pinned

          # Held across the request, so concurrent callers share one discovery.
          @discovery.synchronize { @discovered ||= list_metros }.values
        end

        # The endpoint for a metro code, from what the session already knows.
        # Sends no request. A discovered metro may report an endpoint its code
        # does not build, so that wins over the URL derived from the code.
        #
        # @param metro [String, Symbol]
        # @return [Endpoint]
        def endpoint_for(metro)
          return @pinned if @pinned

          # @discovered is frozen and assigned once, so reading it needs no lock.
          @discovered&.[](metro.to_s) || Metro.endpoint(metro)
        end

        # The endpoints a scope covers. A named scope never discovers.
        #
        # @param scope [:all, Array<String>]
        # @return [Array<Endpoint>]
        def resolve(scope)
          return [@pinned] if @pinned
          return discover if scope == :all
          if scope.empty?
            raise Error.new("An empty metro scope selects no metros; pass :all or a metro.",
                            kind: :fanout)
          end

          scope.map { |metro| endpoint_for(metro) }
        end

        # The one endpoint of an operation that must pick exactly one metro.
        # A wider scope falls back to the default metro, since "create this
        # in every metro" is not a thing a caller can mean; a named scope
        # must hold it, or the call is refused rather than sent elsewhere.
        #
        # @param operation [String] e.g. "Creating an instance"
        # @return [Endpoint]
        # @raise [Unikraft::Cloud::Error] kind `:config` when a scope of
        #   several metros leaves out the default one
        def resolve_one(scope, operation)
          return @pinned if @pinned

          default = @default_endpoint.metro
          return endpoint_for(default) if scope == :all

          endpoints = resolve(scope)
          return endpoints.first if endpoints.size == 1
          return endpoint_for(default) if scope.include?(default)

          metros = endpoints.map(&:metro)
          raise Error.new("#{operation} targets a single metro, but the scope spans " \
                          "#{metros.size} (#{metros.join(", ")}) and leaves out the default " \
                          "metro (#{default}). Pick one with `ukc.metro(:#{metros.first})` " \
                          "or `metros: :#{metros.first}`.",
                          kind: :config)
        end

        # Close every transport this session built (idle connections only;
        # a later call reopens them). Idempotent.
        #
        # @return [nil]
        def close
          transports = @mutex.synchronize { @transports.values }
          # ApiClient#close closes the pooled idle connections. A custom
          # `transport:` need only satisfy request/bytes/stream, so it may not
          # have one.
          transports.each { |t| t.close if t.respond_to?(:close) }
          nil
        end

        def inspect
          "#<#{self.class.name} default=#{@default_endpoint.metro.inspect}" \
            "#{" pinned" if @pinned}>"
        end

        private

        def list_metros
          metros = begin
            Response.list(API::ControlPlane::MetrosApi.new(transport(@controlplane_url)).list_metros,
                          :metros)
          rescue Error => e
            raise Error.new("Could not discover the available metros from the control plane. " \
                            "Name the metros you want (`Unikraft::Cloud.new(metro: :fra)`, " \
                            "`ukc.metro(:fra)`, or `metros: [...]`) to skip discovery.",
                            kind: :fanout, cause: e)
          end
          endpoints = metros.filter_map do |m|
            # The IATA code is what users type; the control plane's endpoint
            # is trusted over one built from it, so new metros just work.
            code = [m[:iata_code], m[:name]].find { |c| c.is_a?(String) && !c.empty? }
            code && [code,
                     Endpoint.new(metro: code, base_url: Metro.base_url(m[:endpoint] || code))]
          end.to_h
          return endpoints.freeze unless endpoints.empty?

          raise Error.new("The control plane reported no metros for this account, so there is " \
                          "nothing to query.", kind: :fanout)
        end
      end
    end
  end
end
