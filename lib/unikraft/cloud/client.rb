# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require_relative "core/http"
require_relative "core/metro"
require_relative "core/session"

module Unikraft
  # The official Ruby SDK for Unikraft Cloud.
  module Cloud
    # The idiomatic resource clients for one metro scope. Reads fan out across
    # the scope and are merged; each result carries the `metro` it came from.
    class Scope
      # @return [Core::Session] the credentials, transports and metro
      #   discovery these clients share
      attr_reader :session
      # @return [:all, Array<String>] the metros these clients cover
      attr_reader :scope
      # @return [Resources::Instances] instances (microVMs)
      attr_reader :instances
      # @return [Resources::Volumes] persistent volumes
      attr_reader :volumes
      # @return [Resources::ServiceGroups] service groups (load-balanced
      #   networking)
      attr_reader :services
      # @return [Resources::Certificates] TLS certificates
      attr_reader :certificates

      # @api private
      def initialize(session, scope, transport = session.transport)
        @session = session
        @scope = scope
        @transport = transport
        @instances = Resources::Instances.new(session, scope, transport)
        @volumes = Resources::Volumes.new(session, scope, transport)
        @services = Resources::ServiceGroups.new(session, scope, transport)
        @certificates = Resources::Certificates.new(session, scope, transport)
      end

      def inspect = "#<#{self.class.name} scope=#{@scope.inspect}>"
    end

    # The resource clients for exactly one metro, from {Client#metro}. The
    # metro is known, so `get(name: ...).suspend` is one request.
    #
    # A sandbox lives in exactly one metro, so `sandboxes` belongs here rather
    # than on {Scope}, built in {#initialize} from `session` and `endpoint`.
    class MetroScope < Scope
      # @return [Core::Endpoint] the metro these clients are pinned to
      attr_reader :endpoint
      # @return [API] the raw API surfaces, the platform one pinned to this
      #   metro
      attr_reader :api

      # @api private
      def initialize(session, endpoint)
        super(session, [endpoint.metro].freeze, session.transport(endpoint.base_url))
        @endpoint = endpoint
        @api = session.api(endpoint.base_url)
      end
    end

    # The Unikraft Cloud SDK entry point, built by {Unikraft::Cloud.new}.
    #
    # By default the client is account-wide: reads cover every metro the
    # account can reach and are merged, each result tagged with its metro.
    # Narrow that with {#metro}, {#metros}, `metros:` on a call, or `metro:`
    # / `metros:` here, which also skips metro discovery.
    #
    # A client is thread-safe and meant to be long-lived: build one and share
    # it. {#close} releases its connections.
    #
    # @example
    #   ukc = Unikraft::Cloud.new(token: ENV["UKC_TOKEN"])
    #   ukc.instances.each { |inst| puts "#{inst.metro} #{inst.name}" }
    #   ukc.metro(:fra).instances.get(name: "web").suspend
    class Client < Scope
      # @return [API] the raw ("plumbing") API surfaces: `api.platform`
      #   (pointing at the default metro unless a call passes `base_url:`)
      #   and `api.controlplane`
      attr_reader :api

      # @param token [String, nil] bearer token; defaults to `UKC_TOKEN`
      # @param metro [String, Symbol, nil] the metro of operations that must
      #   pick one (and the scope, unless `metros:` is given), or a full
      #   `http(s)://` base URL for a self-hosted deployment; defaults to
      #   `UKC_METRO`
      # @param metros [:all, String, Symbol, Array, nil] the default scope;
      #   `:all` (every metro the account reaches) unless `metro:` is set
      # @param base_url [String, nil] an explicit platform base URL;
      #   overrides `metro:`
      # @param control_plane_url [String, nil]
      # @param headers [Hash] sent with every request
      # @param timeout [Numeric, nil] seconds per connect and read
      # @param proxy_from_env [Boolean] honour `http_proxy`/`https_proxy`
      # @param user_agent [String, nil]
      # @param transport [#call, nil] builds the transport from the
      #   {Core::ApiClient} keywords (`base_url:`, `token:`, ...); for tests
      #   or a custom HTTP stack
      def initialize(token: nil, metro: nil, metros: nil, base_url: nil, control_plane_url: nil,
                     headers: {}, timeout: Core::ApiClient::DEFAULT_TIMEOUT, proxy_from_env: true,
                     user_agent: nil, transport: nil)
        metro ||= env("UKC_METRO")
        explicit = base_url || (metro if Core::Metro.url?(metro))
        config = { token: token || env("UKC_TOKEN"), headers:, timeout:, proxy_from_env:,
                   user_agent: }
        session = Core::Session.new(
          config:, transport:, pinned: !explicit.nil?,
          platform_url: Core::Metro.base_url(explicit || metro || DEFAULT_METRO),
          controlplane_url: control_plane_url || CONTROLPLANE_BASE_URL,
          default_metro: (metro || DEFAULT_METRO).to_s
        )
        scope = Core::Metro.scope(metros || metro || :all)
        super(session, scope)
        @api = session.api
        @scopes = {}
        @mutex = Mutex.new
      end

      # The resource clients for one metro, cached.
      #
      # @param metro [String, Symbol]
      # @return [MetroScope]
      def metro(metro)
        endpoint = session.endpoint_for(metro)
        @mutex.synchronize { @scopes[endpoint.base_url] ||= MetroScope.new(session, endpoint) }
      end

      # The resource clients for several metros, or every one.
      #
      # @example
      #   ukc.metros(:fra, :dal).instances.to_a
      #   ukc.metros(:all)
      # @return [Scope]
      def metros(*metros) = Scope.new(session, Core::Metro.scope(metros))

      # Every metro the account can reach, as the control plane reports it,
      # cached for the client's lifetime.
      #
      # @return [Array<Core::Endpoint>] each with `metro` and `base_url`
      def available_metros = session.discover

      # Close every connection the client opened. Idempotent; a later call
      # reopens what it needs.
      #
      # @return [nil]
      def close = session.close

      private

      def env(name)
        value = ENV.fetch(name, nil)
        value unless value.nil? || value.empty?
      end
    end

    class << self
      # Build a client.
      #
      # @example
      #   ukc = Unikraft::Cloud.new(token: ENV["UKC_TOKEN"])
      # @param (see Client#initialize)
      # @return [Client]
      def new(**) = Client.new(**)

      # Build a client, yield it, and close it when the block returns.
      #
      # @example
      #   Unikraft::Cloud.open(metro: :fra) { |ukc| ukc.instances.count }
      # @param (see Client#initialize)
      # @yieldparam ukc [Client]
      # @return [Object] the block's value
      def open(**)
        client = Client.new(**)
        yield client
      ensure
        client&.close
      end
    end
  end
end
