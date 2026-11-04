# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require_relative "../../core/errors"
require_relative "../../core/metro"
require_relative "../../core/response"
require_relative "../instances"
require_relative "sandbox"

module Unikraft
  module Cloud
    module Resources
      # The sandboxes of one metro, as `ukc.metro(:fra).sandboxes`. A sandbox
      # lives in exactly one metro, so this hangs off a metro scope rather
      # than the account-wide client, where `create` could only quietly mean
      # the default metro. Enumerable over the sandboxes in the metro.
      #
      # @example
      #   fra = ukc.metro(:fra)
      #   fra.sandboxes.create(memory_mb: 512) do |sb|
      #     sb.run("make", "test", cwd: "/src")
      #   end
      #   fra.sandboxes.each { |sb| puts sb.uuid }
      class Sandboxes
        include Enumerable

        # The keywords that configure a client: a door that runs through an
        # existing one refuses them rather than ignoring them. `headers:`
        # and `timeout:` are not among them, being per-call options too. A
        # test keeps this in step with {Client#initialize}.
        CLIENT_CONFIG = %i[token metro metros base_url control_plane_url proxy_from_env
                           user_agent transport].freeze

        # The create fields a sandbox sets itself, or cannot honour.
        MANAGED = %i[autostart timeout_s wait_timeout_ms].freeze

        # What creates from a snapshot, which carries the image, the memory
        # and the plugins of its source.
        SNAPSHOT = %i[template branch_from checkpoint].freeze

        # @return [Core::Session]
        attr_reader :session
        # @return [:all, Array<String>] the metros these operations cover
        attr_reader :scope

        # Refuse options that would be silently ignored, the client they
        # configure already existing.
        #
        # @api private
        def self.refuse_client_config!(opts, door, borrowed: false)
          named = opts.keys & (CLIENT_CONFIG + [:client])
          return if named.empty?

          remedies = []
          if named.include?(:client)
            remedies << "run the call through that client's own `sandboxes`"
          end
          config = named - %i[client metro metros]
          unless config.empty?
            remedies << "set #{config.size == 1 ? "it" : "them"} when the client is built " \
                        "(`Unikraft::Cloud.new(#{config.map { |k| "#{k}: ..." }.join(", ")})`)"
          end
          if named.intersect?(%i[metro metros])
            remedies << "pick the metro one step earlier (`ukc.metro(:fra).sandboxes`)"
          end
          remedies << if borrowed
                        "drop `client:`, so that these options build the client instead"
                      else
                        "use `Unikraft::Cloud::Sandbox.create`, which builds a client from them"
                      end
          keys = named.map { |k| "`#{k}:`" }.join(", ")
          raise Error.new("#{door} runs through a client that already exists, so #{keys} " \
                          "would be ignored. To fix it, #{remedies.join(", or ")}.",
                          kind: :config)
        end

        # @api private
        def initialize(session, scope, transport)
          @session = session
          @scope = scope
          @instances = Instances.new(session, scope, transport)
        end

        # Create a sandbox: create the instance with the plugin attached, then
        # wait for the plugin to answer. A failed wait deletes the instance
        # it made, so a broken sandbox does not linger; pass `ready: false`
        # to keep it for inspection.
        #
        # The spec is every field `instances.create` takes, minus the ones a
        # sandbox manages (`autostart`, `timeout_s`, `wait_timeout_ms`,
        # `replicas`), plus `rom:` (shorthand for the plugin's entry in
        # `plugins`) and `plugin_name:`. `image` defaults to
        # `UKC_SANDBOX_IMAGE` or {Sandbox::DEFAULT_IMAGE}, `memory_mb` to
        # {Sandbox::DEFAULT_MEMORY_MB}, `autokill` to
        # {Sandbox::DEFAULT_AUTOKILL_MS}. A `template:`, `branch_from:` or
        # `checkpoint:` carries its image, memory and plugins, so those
        # defaults are left out.
        #
        # With a block, the sandbox is yielded and deleted when the block
        # returns, however it returns.
        #
        # @example
        #   sb = fra.sandboxes.create(image: "my-org/base:latest", env: { "A" => "1" })
        #   fra.sandboxes.create(template: { name: "warm" }) { |sb| sb.run("true") }
        # @param spec [Hash, nil] the spec, or pass it as keywords
        # @param boot_within [Integer, nil] seconds the platform waits for
        #   `running`; {Sandbox::DEFAULT_BOOT_WITHIN}, or 0 with `ready: false`.
        #   The create request is held open meanwhile, so a given value
        #   stretches its read timeout to cover it, unless `timeout:` sets it
        # @param ready [Hash, false] the {Sandbox#ready} policy (`within:`,
        #   ...), or false to return as soon as the instance exists
        # @param headers [Hash, nil]
        # @param timeout [Numeric, nil] the HTTP timeout of each request
        # @yieldparam sandbox [Sandbox]
        # @return [Sandbox, Object] the sandbox, or the block's value
        # @raise [Unikraft::Cloud::Error] kind `:config` for a field a sandbox
        #   manages or a client option
        def create(spec = nil, boot_within: nil, ready: {}, headers: nil, timeout: nil, **kwargs)
          spec = (spec || {}).transform_keys(&:to_sym).merge(kwargs)
          self.class.refuse_client_config!(spec, "`sandboxes.create`")
          check_spec!(spec)
          call = { headers:, timeout: }.compact
          plugin_name = (spec.delete(:plugin_name) || Sandbox::DEFAULT_PLUGIN_NAME).to_s
          body = instance_body(spec, plugin_name, spec.delete(:rom))
          body[:timeout_s] = boot_within || (ready == false ? 0 : Sandbox::DEFAULT_BOOT_WITHIN)
          booting = boot_within&.positive? ? { timeout: boot_within + 10 }.merge(call) : call
          sandbox = attach(create_instance(body, booting), plugin_name)
          ready_or_delete(sandbox, ready, headers) unless ready == false
          return sandbox unless block_given?

          begin
            yield sandbox
          ensure
            # A block that deleted the sandbox itself still ends here.
            Core::Response.absent { sandbox.delete(**call) }
          end
        end

        # Attach to a sandbox that already exists. Nothing waits for the
        # plugin unless `ready:` is given, and nothing is ever deleted.
        #
        # @example
        #   fra.sandboxes.get(uuid: uuid)
        #   fra.sandboxes.get(name: "ci", ready: { within: 10 })
        # @param ref [Hash, nil] or pass `uuid:`/`name:`/`metro:`
        # @param plugin_name [String, nil] the plugin to address; defaults to
        #   the one named {Sandbox::DEFAULT_PLUGIN_NAME}, or the only one
        # @param ready [Hash, nil] probe the plugin with this policy
        # @return [Sandbox]
        def get(ref = nil, plugin_name: nil, ready: nil, **kwargs)
          self.class.refuse_client_config!(kwargs.except(:metro), "`sandboxes.get`")
          call = kwargs.slice(:headers, :timeout)
          handle = @instances.get(ref, **kwargs)
          sandbox = attach(handle, plugin_name_on(handle.model, plugin_name))
          sandbox.ready(**ready, headers: call[:headers]) if ready
          sandbox
        end

        # Every instance in scope carrying the sandbox plugin, as sandboxes.
        # A sandbox is an instance, so this is the instance list, filtered.
        #
        # @param plugin_name [String, nil] the plugin to look for
        # @param opts [Hash] `tags:`, `page_size:`, `metros:`, `base_url:`,
        #   `headers:`, `timeout:`, as `instances.list` takes them
        # @return [Enumerator<Sandbox>] without a block
        def list(plugin_name: nil, **opts, &block)
          wanted = (plugin_name || Sandbox::DEFAULT_PLUGIN_NAME).to_s
          enum = Enumerator.new do |out|
            @instances.list(**opts, details: true).each do |inst|
              next unless inst.plugins&.any? { |p| p[:name] == wanted }

              out << Sandbox.new(session:, endpoint: endpoint_of(inst, opts[:base_url]),
                                 uuid: inst.uuid, plugin_name: wanted)
            end
          end
          block ? enum.each(&block) : enum
        end

        # @yieldparam sandbox [Sandbox]
        def each(&)
          return enum_for(:each) unless block_given?

          list(&)
          self
        end

        def inspect = "#<#{self.class.name} scope=#{@scope.inspect}>"

        private

        def check_spec!(spec)
          if spec.key?(:replicas)
            raise Error.new("A sandbox addresses exactly one instance, so `replicas` would " \
                            "create instances no sandbox wraps. Create one sandbox per call, " \
                            "or replicated instances through `instances.create`.", kind: :config)
          end
          managed = MANAGED & spec.keys
          return if managed.empty?

          raise Error.new("`sandboxes.create` sets #{managed.map { |k| "`#{k}`" }.join(", ")} " \
                          "itself, because a plugin cannot answer in a stopped instance. " \
                          "Control the boot wait with `boot_within:` instead.", kind: :config)
        end

        # The instance create body: the spec, with the defaults it leaves out.
        def instance_body(spec, plugin_name, rom)
          snapshot = SNAPSHOT.any? { |key| spec.key?(key) }
          image = spec.delete(:image)
          # An empty image is as unusable as an absent one.
          image = nil if image.to_s.empty?
          unless snapshot
            image ||= ENV.fetch("UKC_SANDBOX_IMAGE", "")
            image = Sandbox::DEFAULT_IMAGE if image.empty?
            spec[:memory_mb] ||= Sandbox::DEFAULT_MEMORY_MB
          end
          plugins = if snapshot
                      from_snapshot(spec[:plugins], plugin_name, rom)
                    else
                      with_plugin(spec[:plugins], plugin_name, rom)
                    end
          autokill = spec[:autokill] || { time_ms: Sandbox::DEFAULT_AUTOKILL_MS }
          { **spec, image:, plugins:, autokill:, autostart: true }.compact
        end

        # The caller's plugins plus the sandbox plugin. An entry already named
        # `plugin_name` is the sandbox plugin, and keeps its `config`.
        def with_plugin(plugins, plugin_name, rom)
          plugins = Array(plugins)
          unless named?(plugins, plugin_name)
            return [{ name: plugin_name, rom: rom || Sandbox::DEFAULT_PLUGIN_ROM }, *plugins]
          end
          return plugins if rom.nil?

          raise Error.new("The spec attaches a plugin named \"#{plugin_name}\" in `plugins` and " \
                          "also passes `rom:`, so there are two ROMs for one plugin. Keep the " \
                          "`plugins` entry, which can also carry `config`, and drop `rom:`.",
                          kind: :config)
        end

        # A snapshot already carries the sandbox plugin: attaching it again
        # is refused by the platform, so it is refused here first.
        def from_snapshot(plugins, plugin_name, rom)
          return plugins if rom.nil? && !named?(Array(plugins), plugin_name)

          raise Error.new("The spec creates the sandbox from a template, a branch source, or " \
                          "a checkpoint, which already carries the sandbox plugin, so `rom:` " \
                          "or a `plugins` entry named \"#{plugin_name}\" would attach it twice. " \
                          "Drop it. If the source attached the plugin under another name, pass " \
                          "that name as `plugin_name:`.", kind: :config)
        end

        def named?(plugins, name) = plugins.any? { |p| (p[:name] || p["name"]).to_s == name }

        def create_instance(body, call)
          @instances.create(body, **call)
        rescue Error => e
          raise unless e.kind == :network

          # The reply carries the UUID, so a request that failed on the way
          # back leaves nothing to address, and autokill counts stopped time.
          raise Error.new("#{e.message} The platform may have created the instance before this " \
                          "failed. If it did, it is running, and neither this call nor " \
                          "`autokill` removes it: find it with `sandboxes.list` and delete it.",
                          kind: e.kind, status: e.status, errors: e.errors, body: e.body,
                          cause: e.cause)
        end

        # Wait for the plugin, and delete the instance this call made when
        # the wait fails: a running instance with a silent plugin never stops
        # on its own, so autokill would never reach it.
        def ready_or_delete(sandbox, policy, headers)
          sandbox.ready(**policy, headers:)
        rescue Exception => e # rubocop:disable Lint/RescueException -- an interrupt leaks it too
          deleted = begin
            sandbox.delete(**{ headers: }.compact)
            true
          rescue StandardError
            false
          end
          raise unless deleted && e.is_a?(Error)

          raise Error.new("#{e.message} The sandbox was deleted. To inspect a sandbox that " \
                          "fails like this, create it with `ready: false`, which skips this " \
                          "wait and keeps it for you to probe and delete.",
                          kind: e.kind, status: e.status, errors: e.errors, body: e.body,
                          cause: e.cause)
        end

        # A sandbox on an instance handle, at the endpoint it was found at.
        def attach(handle, plugin_name)
          loc = handle.location
          Sandbox.new(session:, uuid: handle.uuid, plugin_name:,
                      endpoint: Core::Endpoint.new(metro: loc.metro, base_url: loc.base_url))
        end

        # A listed instance's endpoint: a per-call `base_url:` wins over the
        # metro, so the plugin is reached on the cluster the list came from.
        def endpoint_of(inst, base_url)
          return @session.endpoint_for(inst.metro) unless base_url

          url = Core::Metro.base_url(base_url)
          Core::Endpoint.new(metro: url, base_url: url)
        end

        # Which plugin on an instance is the sandbox: the one asked for, the
        # conventional one, or the only one there is.
        def plugin_name_on(inst, requested)
          plugins = inst.plugins
          names = Array(plugins).map { |p| p[:name] }
          if requested
            # No plugins listed is not evidence of absence; only a list can
            # contradict the caller.
            return requested.to_s if plugins.nil? || names.include?(requested.to_s)

            has = names.empty? ? "it has no plugins" : "it has: #{names.join(", ")}"
            raise Error.new("Instance #{inst.uuid} carries no plugin named \"#{requested}\" " \
                            "(#{has}).", kind: :http, status: 404, body: inst)
          end
          return Sandbox::DEFAULT_PLUGIN_NAME if names.include?(Sandbox::DEFAULT_PLUGIN_NAME)
          return names.first if names.size == 1
          if names.empty?
            raise Error.new("Instance #{inst.uuid} has no plugins attached, so it is not a " \
                            "sandbox.", kind: :http, status: 404, body: inst)
          end

          raise Error.new("Instance #{inst.uuid} carries #{names.size} plugins " \
                          "(#{names.join(", ")}) and none is named " \
                          "\"#{Sandbox::DEFAULT_PLUGIN_NAME}\". Say which one with " \
                          "`plugin_name:`.", kind: :config, body: inst)
        end
      end
    end
  end
end
