# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require_relative "patch"
require_relative "ref"
require_relative "response"
require_relative "../model"

module Unikraft
  module Cloud
    module Core
      # Where a resource was found, and the resource itself when finding it
      # already read it.
      Located = Data.define(:location, :value)

      # A reference to one resource in one metro.
      #
      # `get` returns a handle without sending anything. Reading an attribute
      # (`handle.state`) resolves it once: it locates the resource if the
      # scope spans several metros, reads it, and memoizes the result.
      #
      # Ruby has no `await`, and a lazy mutation that nobody forces would
      # silently never run, so mutations (`delete`, `update`, `apply`, and
      # each resource's own verbs) run immediately. Each returns a new handle
      # carrying what the endpoint reported, at the same location, so calls
      # still chain:
      #
      #   ukc.instances.get(name: "web").suspend.state  # => "standby"
      #
      # A handle is meant for one thread. The client behind it is shared.
      class Handle
        class << self
          # Define a reader per attribute of the resource's model, resolving
          # the handle on first use. Names the handle already answers keep
          # their own meaning.
          #
          # @param klass [Class<Model>]
          def attributes_of(klass)
            klass.attributes.each_key do |name|
              next if method_defined?(name) || private_method_defined?(name)

              define_method(name) { attribute(name) }
            end
          end
        end

        # @api private
        # @param partial [Boolean] `located.value` is a mutation's reply,
        #   which may leave out attributes the resource has
        def initialize(resource, ref, opts = {}, located: nil, partial: false, &locator)
          @resource = resource
          @ref = ref
          @opts = opts
          @located = located
          @locator = locator
          @model = located&.value
          @partial = partial
        end

        # Where the resource lives, locating it first if the scope spans
        # several metros. Raises {AmbiguousRefError} when a name matches in
        # more than one. An operation's own `headers:`/`timeout:` apply to
        # that lookup too, over those given to `get`.
        #
        # @param call [Hash] `headers:`, `timeout:`
        # @return [Location]
        def location(**call)
          (@located ||= @locator.call(call_opts(call))).location
        end
        alias resolve location

        # @return [String] the metro holding the resource
        def metro = location.metro

        # The resource: what the endpoint reported for a handle a mutation
        # returned, or else the resource read once and memoized.
        #
        # @return [Model]
        def model
          @model ||= (@located ||= @locator.call).value || @resource.fetch(location,
                                                                           **call_opts(@opts))
        end

        # Read the resource again (in place, like ActiveRecord's reload).
        #
        # @return [self]
        def reload(**call)
          @model = @resource.fetch(location(**call), **call_opts(@opts), **call)
          @partial = false
          self
        end

        # @return [Object] a field by its wire key, declared or not
        def [](key) = model[key]

        # @return [Hash]
        def to_h = model.to_h

        def deconstruct_keys(keys) = model.deconstruct_keys(keys)

        # Delete the resource.
        #
        # @param call [Hash] `headers:`, `timeout:`
        # @return [Handle] carrying what the endpoint reported
        def delete(**call) = mutate(@resource.spec.delete, [wire(call)], **call)

        # Change the resource's properties. A value sets a property, nil
        # removes it, an omitted one is left alone. `headers:` and
        # `timeout:` are always call options, never properties. Raw
        # `{prop:, op:, value:}` triples (or a Hash) go positionally.
        #
        # @example
        #   inst.update(memory_mb: 512, autokill: nil, timeout: 10)
        #   inst.update([{ prop: "memory_mb", op: "set", value: 512 }])
        # @return [Handle] carrying the updated resource
        def update(changes = nil, **kwargs)
          call = kwargs.slice(:headers, :timeout)
          props = kwargs.except(*call.keys)
          if changes && props.any?
            raise ArgumentError, "pass the changes positionally or as keywords, not both"
          end

          patch(Patch.changes(changes || props), **call)
        end

        # Stage several operations and send them as one update, at the end of
        # the block or on {Patch::Editor#apply}.
        #
        # @example
        #   inst.edit.set(memory_mb: 512).add(tags: ["prod"]).apply
        #   inst.edit { |e| e.remove(env: ["OLD"]) }
        # @yieldparam editor [Patch::Editor]
        # @return [Patch::Editor, Handle] the editor, or the applied result
        def edit(**call)
          editor = Patch::Editor.new(@resource.spec.noun) { |items| patch(items, **call) }
          return editor unless block_given?

          yield editor
          editor.apply
        end

        def method_missing(name, *args, &)
          return super unless args.empty? && loaded_attribute?(name)

          @model[name]
        end

        def respond_to_missing?(name, include_private = false)
          loaded_attribute?(name) || super
        end

        def inspect
          return "#<#{self.class.name} #{@ref} (not loaded)>" unless @model

          "#<#{self.class.name} #{@model.inspect_fields}>"
        end
        alias to_s inspect

        protected

        # The ref as the request body carries it.
        def wire(call = {}) = location(**call).ref.wire

        # Send update triples to where the resource lives.
        def patch(items, **call)
          mutate(@resource.spec.update, items.map { |item| wire(call).merge(item) }, **call)
        end

        # Send one operation with `body` to the resource's metro, and return
        # a handle on what it reported.
        def mutate(operation, body, **call)
          call = effective(call)
          loc = location(**call)
          res = @resource.api.public_send(operation, body:, **@resource.call_options(loc, call))
          following(loc, one(res), call)
        end

        # Unwrap a single-resource response, tagged with the metro.
        def one(res, key = @resource.spec.key)
          Response.first(res, key, "#{@resource.spec.noun} #{location.ref}").with_metro(metro)
        end

        # The handle a mutation returns keeps the options it ran with, so a
        # later read uses the same credentials.
        def following(loc, value, call = {})
          self.class.new(@resource, loc.ref, @opts.merge(call_opts(call)),
                         located: Located.new(location: loc, value:), partial: true)
        end

        # A declared attribute. A mutation's reply may leave it out; then
        # the resource is read once to fill it in.
        def attribute(name)
          value = model[name]
          return value unless value.nil? && @partial

          reload(**call_opts(@opts))[name]
        end

        def call_opts(opts) = opts.slice(:headers, :timeout)

        # An operation's options over the `headers:`/`timeout:` given to `get`.
        def effective(call) = call_opts(@opts).merge(call)

        private

        def loaded_attribute?(name)
          @model.is_a?(Model) && @model.class.attributes.key?(name)
        end
      end
    end
  end
end
