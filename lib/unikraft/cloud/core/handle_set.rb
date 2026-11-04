# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# Acting on every metro that holds a name. Names are unique within a metro,
# not across them, so one name can legitimately refer to a resource in every
# metro. `where(name: ...)` addresses all of them at once, on purpose.

require_relative "fanout"
require_relative "patch"

module Unikraft
  module Cloud
    module Core
      # Every resource matching one ref, one per metro. Enumerable over the
      # resources; each operation runs in every metro concurrently and
      # returns an Array with one result per metro. When some metros fail,
      # the successes ride on the {MetroFanoutError} as `results`.
      #
      # The matches are located once, on first use.
      #
      # @example
      #   web = ukc.instances.where(name: "web")
      #   web.metros          # => ["fra", "dal"]
      #   web.map(&:state)    # => ["running", "standby"]
      #   web.suspend         # => [handle, handle]
      class HandleSet
        include Enumerable

        class << self
          # Expose a handle operation on the set.
          #
          # @param names [Array<Symbol>]
          def forward(*names)
            names.each do |name|
              define_method(name) do |*args, **kw, &block|
                fan(kw) { |handle| handle.public_send(name, *args, **kw, &block) }
              end
            end
          end
        end

        # @api private
        def initialize(noun, &locate)
          @noun = noun
          @locate = locate
        end

        # @param call [Hash] `headers:`/`timeout:` for the lookup, over
        #   those given to `where`; only the first use locates
        # @return [Array<Handle>] one per metro holding a match
        def handles(**call)
          @handles ||= @locate.call(call.slice(:headers, :timeout)).freeze
        end

        # Yield each match's resource.
        #
        # @yieldparam resource [Model]
        def each(&)
          return enum_for(:each) { size } unless block_given?

          handles.each { |handle| yield handle.model }
          self
        end

        # @return [Array<String>] the metros holding a match
        def metros = handles.map(&:metro)

        # @return [Integer] how many metros hold a match
        def size = handles.size
        alias length size

        forward :delete, :update

        # Read every match again, in place.
        #
        # @return [self]
        def reload(**call)
          fan(call) { |handle| handle.reload(**call) }
          self
        end

        # Stage changes once and apply them to every match.
        #
        # @return [Patch::Editor, Array<Handle>]
        def edit(**call)
          editor = Patch::Editor.new(@noun) do |items|
            fan(call) { |handle| handle.update(items, **call) }
          end
          return editor unless block_given?

          yield editor
          editor.apply
        end

        def inspect = "#<#{self.class.name} #{@handles ? metros.inspect : "(not located)"}>"

        private

        def fan(call = {}, &) = Fanout.all(handles(**call), &)
      end
    end
  end
end
