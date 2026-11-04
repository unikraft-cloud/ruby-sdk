# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require_relative "../core/resource"
require_relative "../api/platform"

module Unikraft
  module Cloud
    # The idiomatic ("porcelain") resource clients.
    module Resources
      # A handle on one instance (see {Core::Handle}). Readers such as
      # `state` and `memory_mb` resolve it once; `running?`, `stopped?` and
      # the other predicates compare `state` with each API state.
      #
      # @example
      #   web = ukc.instances.get(name: "web")
      #   web.running?                          # one read, memoized
      #   web.suspend.state                     # => "standby"
      #   fra.instances.create(image: "nginx:latest")
      #      .wait(state: :running, within: 30)
      #      .logs(offset: -4096)
      class InstanceHandle < Core::Handle
        # Start the instance.
        # @return [InstanceHandle] carrying what the endpoint reported
        def start(**call) = mutate(:start_instances, [wire(call)], **call)

        # Stop the instance.
        # @return [InstanceHandle]
        def stop(**call) = mutate(:stop_instances, [wire(call)], **call)

        # Suspend the instance.
        # @return [InstanceHandle]
        def suspend(**call) = mutate(:suspend_instances, [wire(call)], **call)

        # Block until the instance reaches a state. The platform holds the
        # request open until then, and fails it when `within` passes first,
        # so this raises rather than returning.
        #
        # @param state [Symbol, String, nil] e.g. `:running` (the API's
        #   default)
        # @param within [Integer, nil] seconds the platform waits; -1 waits
        #   indefinitely. The read timeout of the request is stretched to
        #   cover it, unless `timeout:` sets it.
        # @param call [Hash] `headers:`, `timeout:` (the HTTP timeout, as
        #   on every call)
        # @return [InstanceHandle] carrying the observed state
        def wait(state: nil, within: nil, **call)
          http = call
          # The connection must outlive the server-side wait.
          http = { timeout: within.negative? ? nil : within + 10 }.merge(call) if within
          http = effective(http)
          loc = location(**http)
          res = @resource.api.wait_instances(**loc.ref.query, state: state && [state.to_s],
                                                              timeout_s: within && [within],
                                                              **@resource.call_options(loc, http))
          following(loc, one(res), effective(call))
        end

        # The console log. `output` is base64, as the API sends it.
        #
        # @param offset [Integer, nil] byte offset; negative counts from the end
        # @param limit [Integer, nil] at most this many bytes
        # @return [Model] tagged with the metro
        def logs(offset: nil, limit: nil, **call)
          call = effective(call)
          loc = location(**call)
          one(@resource.api.get_instance_logs(**loc.ref.query, offset: offset && [offset],
                                                               limit: limit && [limit],
                                                               **@resource.call_options(loc, call)))
        end

        # Resource-usage metrics.
        # @return [Model]
        def metrics(**call)
          call = effective(call)
          loc = location(**call)
          one(@resource.api.get_instance_metrics(**loc.ref.query,
                                                 **@resource.call_options(loc, call)))
        end

        # The state-change history: this instance's entries, each tagged
        # with the metro. A failed per-instance result raises.
        # @return [Array<Model>]
        def history(**call)
          call = effective(call)
          loc = location(**call)
          res = @resource.api.get_instance_history(**loc.ref.query,
                                                   **@resource.call_options(loc, call))
          Array(one(res, :instances)[:history]).map { |entry| entry.with_metro(loc.metro) }
        end

        API::Platform::Models::InstanceState::ALL.each do |value|
          define_method(:"#{value}?") { state == value }
        end

        attributes_of API::Platform::Models::Instance
      end

      # Every instance matching one ref, one per metro (see
      # {Core::HandleSet}).
      #
      # @example
      #   ukc.instances.where(name: "web").suspend
      class InstanceSet < Core::HandleSet
        forward :start, :stop, :suspend, :wait, :logs, :metrics, :history
      end

      # Instances (microVMs). Enumerable over every instance in scope.
      #
      # @example
      #   ukc.instances.list(details: true).each { |i| puts "#{i.metro} #{i.name}" }
      #   ukc.instances.select { |i| i.state == "running" }
      #   ukc.instances.get(name: "web").suspend
      #   ukc.instances.stop([{ name: "a" }, { name: "b" }])
      class Instances < Core::Resource
        API_CLASS = API::Platform::InstancesApi
        HANDLE = InstanceHandle
        SET = InstanceSet
        SPEC = Spec.new(noun: "instance", key: :instances, list: :get_instances,
                        create: :create_instance, delete: :delete_instances,
                        update: :update_instances)

        # Start one or more instances, in whichever metros hold them.
        # @param (see Core::Resource#delete)
        # @return [Array<Model>]
        def start(refs = nil, **kwargs) = bulk(:start_instances, refs, kwargs)

        # Stop one or more instances.
        # @return [Array<Model>]
        def stop(refs = nil, **kwargs) = bulk(:stop_instances, refs, kwargs)

        # Suspend one or more instances.
        # @return [Array<Model>]
        def suspend(refs = nil, **kwargs) = bulk(:suspend_instances, refs, kwargs)

        # Shorthand for `get(ref).wait(...)`: the ref keys (and `metros:`)
        # locate the instance, the rest go to the operation.
        #
        # @example
        #   ukc.instances.wait(name: "web", state: :running, within: 30)
        # @return [InstanceHandle]
        def wait(ref = nil, **kwargs)
          handle, rest = on(ref, kwargs)
          handle.wait(**rest)
        end

        # Shorthand for `get(ref).logs(...)`.
        # @return [Model]
        def logs(ref = nil, **kwargs)
          handle, rest = on(ref, kwargs)
          handle.logs(**rest)
        end

        # Shorthand for `get(ref).metrics`.
        # @return [Model]
        def metrics(ref = nil, **kwargs)
          handle, rest = on(ref, kwargs)
          handle.metrics(**rest)
        end

        # Shorthand for `get(ref).history`.
        # @return [Array<Model>]
        def history(ref = nil, **kwargs)
          handle, rest = on(ref, kwargs)
          handle.history(**rest)
        end
      end
    end
  end
end
