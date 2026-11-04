# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# A sandbox spans two APIs. The platform creates the virtual machine and
# attaches the plugin; the plugin's own API runs commands inside it. The
# plugin is addressed under the name it was attached with, not the
# specification's `servers` block, and a sandbox borrows the client's session
# rather than resolving credentials of its own.

require "unikraft/cloud/plugin/sandbox/api"

require_relative "../../core/errors"
require_relative "../../core/metro"
require_relative "../../core/ready"
require_relative "../../core/ref"
require_relative "../../core/response"
require_relative "../../core/url"
require_relative "../instances"
require_relative "command"
require_relative "files"

module Unikraft
  module Cloud
    # One virtual machine with the sandbox plugin attached: it runs whatever
    # command it is handed. Commands and files go to the plugin's endpoint,
    # a route under that machine; {#instance} is the machine itself.
    #
    # There are two ways in. {Sandbox.create} builds a client from its
    # options; `ukc.metro(:fra).sandboxes.create` borrows one you hold. With
    # a block, either deletes the sandbox when the block returns, however it
    # returns.
    #
    # @example
    #   Unikraft::Cloud::Sandbox.create do |sb|
    #     sb.run("echo hello").stdout                # => "hello\n"
    #     sb.files.write("/tmp/a.txt", "hello")
    #     sb.instance.update(memory_mb: 4096)        # it is a real instance
    #   end
    class Sandbox
      # The plugin name, and so the URL segment, used when the caller names
      # none.
      DEFAULT_PLUGIN_NAME = Plugin::Sandbox::API::PLUGIN_NAME

      # The prebuilt sandbox plugin ROM used when the caller names none.
      DEFAULT_PLUGIN_ROM = "plugins/sandbox:latest"

      # The image a sandbox boots when the caller names none, unless
      # `UKC_SANDBOX_IMAGE` names another. A replacement must carry a shell
      # and a main process that stays alive.
      DEFAULT_IMAGE = "debian-slim:latest"

      # Memory, in megabytes: sized for a compiler or a test suite rather
      # than for one small service.
      DEFAULT_MEMORY_MB = 2048

      # How long a stopped sandbox is kept before the platform deletes it, in
      # milliseconds. It counts stopped time only, so a running sandbox is
      # untouched.
      DEFAULT_AUTOKILL_MS = 300_000

      # How long `create` waits for the machine to reach `running`, in
      # seconds.
      DEFAULT_BOOT_WITHIN = 30

      # What a finished command produced. `exitcode` is nil when the
      # `within:` of {Sandbox#run} ran out; the command then keeps running,
      # and its record is kept, so `uuid` stays addressable through
      # {Sandbox#command}.
      Result = Data.define(:uuid, :stdout, :stderr, :exitcode) do
        # @return [Boolean] whether the command exited with status 0
        def success? = exitcode.is_a?(Integer) && exitcode.zero?
      end

      # `stop_reason` bits only a running instance can set: [A]pp (bit 1)
      # for an application that exited, [K]ernel (bit 0) for a kernel that did.
      STOP_REASON_RAN = 0b00011
      private_constant :STOP_REASON_RAN

      # @return [String] the instance's UUID
      attr_reader :uuid
      # @return [String] the metro the sandbox lives in
      attr_reader :metro
      # @return [String] the name the plugin is attached under, also its URL
      #   segment
      attr_reader :plugin_name
      # @return [Core::Session] the credentials and metro knowledge it runs on,
      #   shared with the client it came from
      attr_reader :session
      # @return [String] the plugin's endpoint
      attr_reader :base_url
      # @return [Plugin::Sandbox::API::Client] the raw ("plumbing") plugin API,
      #   pinned to this sandbox: `api.commands` and `api.fs`, returning the
      #   envelopes untouched
      attr_reader :api
      # @return [Files] the filesystem inside the sandbox
      attr_reader :files

      class << self
        # Create a sandbox through a client built from the options, the way
        # `Unikraft::Cloud.new` takes them (`token:` or `UKC_TOKEN`, `metro:`
        # or `UKC_METRO`, ...), or through a borrowed `client:`. The rest is
        # {Resources::Sandboxes#create}'s. With a block, the sandbox is
        # deleted, and a client built here closed, when the block returns.
        #
        # @example
        #   Unikraft::Cloud::Sandbox.create(image: "my-org/base:latest", metro: :fra) do |sb|
        #     puts sb.run("uname -a").stdout
        #   end
        # @param spec [Hash, nil] see {Resources::Sandboxes#create}
        # @param client [Client, nil] borrow this client
        # @yieldparam sandbox [Sandbox]
        # @return [Sandbox, Object] the sandbox, or the block's value
        def create(spec = nil, client: nil, **kwargs, &)
          ukc, rest, scope = door(client, kwargs, "`Sandbox.create(spec, client:)`")
          endpoint = ukc.session.resolve_one(scope, "Creating a sandbox")
          ukc.metro(endpoint.metro).sandboxes.create(spec, **rest, &)
        ensure
          ukc&.close if block_given? && client.nil?
        end

        # Attach to a sandbox that already exists. An instance UUID is
        # metro-scoped, so a ref without `metro:` is searched for across the
        # scope; name the metro to skip the search.
        #
        # @example
        #   sb = Unikraft::Cloud::Sandbox.connect(uuid: uuid, metro: :fra)
        # @param ref [Hash, nil] or pass `uuid:`/`name:`/`metro:`
        # @param client [Client, nil] borrow this client
        # @return [Sandbox]
        def connect(ref = nil, client: nil, **kwargs)
          ref_kw = kwargs.slice(*Core::Ref.members)
          ukc, rest, scope = door(client, kwargs.except(*Core::Ref.members),
                                  "`Sandbox.connect(ref, client:)`")
          Resources::Sandboxes.new(ukc.session, scope, ukc.session.transport)
                              .get(ref, **ref_kw, **rest)
        end

        private

        # The client a static door runs through, the options left for the
        # call, and the metro scope. Credentials are only ever resolved by
        # building a client.
        def door(client, kwargs, name)
          picked = kwargs[:metros] || kwargs[:metro]
          if client
            Resources::Sandboxes.refuse_client_config!(kwargs.except(:metro, :metros), name,
                                                       borrowed: true)
            scope = picked ? Core::Metro.scope(picked) : client.scope
            return [client, kwargs.except(:metro, :metros), scope]
          end

          config = kwargs.slice(*Resources::Sandboxes::CLIENT_CONFIG)
          token = config[:token] || ENV.fetch("UKC_TOKEN", nil)
          if token.to_s.empty?
            raise Error.new("UKC_TOKEN is missing or empty; set it, or pass a token: " \
                            "`Sandbox.create(token: ...)`, or use a client: " \
                            "`Unikraft::Cloud.new(token: ...).metro(:fra).sandboxes.create`.",
                            kind: :config)
          end
          ukc = Client.new(**config)
          [ukc, kwargs.except(*Resources::Sandboxes::CLIENT_CONFIG), ukc.scope]
        end
      end

      # @api private
      # @param endpoint [Core::Endpoint] the endpoint the instance was reached
      #   through, which a pinned or discovered metro makes unguessable from
      #   its code
      def initialize(session:, endpoint:, uuid:, plugin_name:)
        @session = session
        @endpoint = endpoint
        @uuid = uuid
        @metro = endpoint.metro
        @plugin_name = plugin_name
        # Built here rather than read from the specification, whose server URL
        # omits `/v1` and hardcodes `sandbox` as the plugin's name.
        @base_url = "#{Core::URL.strip_trailing_slashes(endpoint.base_url)}/v1/instances/" \
                    "#{uuid}/plugins/#{plugin_name}"
        # The SDK's own transport, so a plugin failure is a Unikraft::Cloud::Error.
        @api = Plugin::Sandbox::API.new(session.transport(@base_url))
        @instances = Resources::Instances.new(session, [@metro],
                                              session.transport(endpoint.base_url))
        @files = Files.new(self)
      end

      # The instance underneath, as a lazy handle (see {Core::Handle}). Each
      # call returns a fresh handle, so keep it to read it twice.
      #
      # @example
      #   sb.instance.state
      #   sb.instance.update(memory_mb: 4096)
      # @return [Resources::InstanceHandle]
      def instance
        ref = Core::Ref.new(uuid:, metro:)
        location = Core::Location.new(ref:, metro:, base_url: @endpoint.base_url)
        Resources::InstanceHandle.new(@instances, ref, {},
                                      located: Core::Located.new(location:, value: nil))
      end

      # Wait until the plugin answers. `create` does this for you; call it
      # after `create(ready: false)`, or after a start or a resume from
      # standby, where the plugin reloads. When the wait runs out, the error
      # names the likely cause, read from the instance.
      #
      # @example
      #   sb.ready(within: 10)
      # @param within [Numeric] seconds to keep probing; each probe's HTTP
      #   timeout is the time left
      # @param headers [Hash, nil] sent with each probe
      # @param policy [Hash] `initial_delay:`, `max_delay:` in seconds (see
      #   {Core::Ready.wait_until_ready})
      # @return [self]
      # @raise [Unikraft::Cloud::Error] kind `:timeout`
      def ready(within: Core::Ready::DEFAULTS[:timeout], headers: nil, **policy)
        # ListCommands is the probe the specification nominates
        # (`x-unikraft-plugin-readiness`); a booting instance answers it with
        # 404 or 502, which the loop retries.
        Core::Ready.wait_until_ready(**policy, timeout: within, what: "sandbox #{uuid}",
                                               diagnose: ->(_) { diagnose }) do |left|
          api.commands.list_commands(headers:, timeout: left)
        end
        self
      end

      # Run a command, wait for it to exit, and return its output: one
      # String is a shell command line, several are an argument vector run
      # directly, as with `Kernel#system`. A failing command is not an
      # error; check {Result#success?}.
      #
      # A `within:` that runs out is not an error either: the result has
      # the output so far and a nil `exitcode`, and the command keeps
      # running. Otherwise the command's record is deleted, unless `keep:`.
      #
      # @example
      #   sb.run("echo hello").stdout                 # => "hello\n"
      #   sb.run("ls", "-la", cwd: "/tmp").success?
      #   sb.run("make", within: 600)
      # @param cmd [Array<String>]
      # @param cwd [String, nil]
      # @param env [Hash{String => String}, nil]
      # @param keep [Boolean] keep the record, to read its logs again later
      # @param within [Numeric, nil] seconds to wait before giving up (see
      #   {Command#wait})
      # @param call [Hash] `headers:`, `timeout:` (the HTTP timeout of each
      #   request)
      # @return [Result]
      def run(*cmd, cwd: nil, env: nil, keep: false, within: nil, **call)
        command = spawn(*cmd, cwd:, env:, **call)
        command.wait(within:, **call)
        exitcode = command.info(**call)&.exitcode
        logs = command.logs(**call)
        command.delete(**call) unless keep || exitcode.nil?
        Result.new(uuid: command.uuid, stdout: logs.stdout, stderr: logs.stderr, exitcode:)
      end

      # Start a command and return at once, without waiting for it.
      #
      # @example
      #   server = sb.spawn("python3 -m http.server", cwd: "/srv")
      #   server.signal(:TERM)
      # @param (see #run)
      # @param call [Hash] `headers:`, `timeout:`
      # @return [Command]
      def spawn(*cmd, cwd: nil, env: nil, **call)
        raise ArgumentError, "no command given" if cmd.empty?

        cmd = cmd.first if cmd.size == 1
        res = api.commands.run_command(body: { cmd:, cwd:, env: }.compact, **call)
        uuid = Core::Response.unwrap(res)&.uuid
        return Command.new(self, uuid) if uuid

        raise Error.new("The sandbox started a command but reported no UUID for it.",
                        kind: :http, body: res)
      end

      # Every command the sandbox knows about, in the order they started.
      #
      # @return [Array<Command>]
      def commands(**call)
        Core::Response.list(api.commands.list_commands(**call), :commands)
                      .map { |uuid| Command.new(self, uuid) }
      end

      # A command by UUID, without a request: one kept by `run(keep: true)`,
      # or started by another process.
      #
      # @return [Command]
      def command(uuid) = Command.new(self, uuid.to_s)

      # Delete the sandbox, which deletes the instance underneath it.
      #
      # @param call [Hash] `headers:`, `timeout:`
      # @return [Resources::InstanceHandle] carrying what the platform reported
      def delete(**call) = instance.delete(**call)

      def inspect
        "#<#{self.class.name} #{uuid} metro=#{metro.inspect} plugin=#{plugin_name.inspect}>"
      end

      private

      # Name the cause once a readiness wait ran out of time. The silent
      # plugin is the symptom; the instance's own state usually says why.
      def diagnose
        inst = instance.model
        plugins = inst.plugins
        plugin = plugins&.find { |p| p[:name] == plugin_name }
        case inst.state
        when "running" then diagnose_running(plugins, plugin)
        when "standby"
          'the instance is in "standby", asleep. A plugin request wakes it, so this is a ' \
          "slow wake rather than a refusal: raise `ready: { within: }`. If you suspended " \
          "it yourself, start it (`sb.instance.start.wait(state: :running)`) and call " \
          "`sb.ready` again"
        when "starting"
          'the instance is still "starting", so it only needs longer. Raise ' \
          "`ready: { within: }`, or `boot_within:` on `create`"
        else diagnose_down(inst, plugin)
        end
      end

      def diagnose_running(plugins, plugin)
        if plugins && plugin.nil?
          if plugins.empty?
            return "the instance is running but carries no plugin at all, so nothing answers " \
                   "at `#{plugin_name}`"
          end

          return "the instance is running but carries no plugin named `#{plugin_name}`, " \
                 "only #{plugins.map { |p| "`#{p[:name]}`" }.join(", ")}. Pass the name it " \
                 "does carry as `plugin_name:`"
        end
        rom = plugin ? " and that its ROM (`#{plugin[:rom]}`) is a sandbox plugin image" : ""
        "the instance is running, so it is the sandbox plugin that did not answer. Read the " \
          "instance's console log (`sb.instance.logs`), which carries the plugin's own " \
          "output#{rom}"
      end

      def diagnose_down(inst, plugin)
        state = inst.state ? %(the instance is "#{inst.state}") : "the instance reported no state"
        unless started?(inst)
          # An image or ROM that could not be pulled: the console log is empty.
          roms = ["`#{inst.image}`", plugin && "`#{plugin[:rom]}`"].compact
          return "#{state} and never started, so nothing inside it has run yet. The usual " \
                 "cause is an image the platform could not fetch or boot: check that " \
                 "#{roms.join(" or ")} #{roms.size > 1 ? "both exist" : "exists"}, and that " \
                 "this account can read #{roms.size > 1 ? "them" : "it"}"
        end
        exit = inst.exit_code.nil? ? "" : ", having exited with code #{inst.exit_code}"
        "#{state}#{exit}, and the sandbox plugin runs inside the instance, so nothing " \
          "answers while it is down. Start it again (`sb.instance.start`) and read the " \
          "console log (`sb.instance.logs`); a base image whose main process exits at once " \
          "stops the instance with it"
      end

      # Whether anything ever ran inside an instance: three witnesses, each
      # optional on the wire.
      def started?(inst)
        inst.start_count.to_i.positive? || !inst.started_at.nil? ||
          inst.stop_reason.to_i.anybits?(STOP_REASON_RAN)
      end
    end
  end
end
