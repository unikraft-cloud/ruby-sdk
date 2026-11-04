# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# Updating a resource. The API models an update as a list of
# `{ prop:, op:, value: }` triples. This turns that into two idiomatic forms,
# both sent as one request:
#
#   update(memory_mb: 512, autokill: nil)       # ops inferred
#   edit.set(...).add(...).remove(...).apply   # ops stated outright

module Unikraft
  module Cloud
    module Core
      # Patch triples from keyword arguments.
      module Patch
        module_function

        # Turn a patch into triples. A value takes `operation`; nil removes the
        # property outright (JSON Merge Patch), whichever method supplied it.
        # Omitted properties are left alone.
        #
        # @param patch [Hash{Symbol => Object}]
        # @param operation ["set", "add", "del"]
        # @return [Array<Hash>]
        def items(patch, operation)
          patch.map do |prop, value|
            value.nil? ? { prop: prop.to_s, op: "del" } : { prop: prop.to_s, op: operation, value: }
          end
        end

        # The triples of an `update`: a patch Hash, or raw triples as an
        # escape hatch.
        #
        # @param changes [Hash, Array<Hash>]
        # @return [Array<Hash>]
        def changes(changes)
          list = if changes.is_a?(Array)
                   changes.map { |c| c.transform_keys(&:to_sym) }
                 else
                   items(changes, "set")
                 end
          raise ArgumentError, "nothing to update" if list.empty?

          list
        end

        # A staged edit: chain {#set}, {#add} and {#remove}, then {#apply} to
        # send every change in one request, in the order written.
        #
        # @example
        #   inst.edit.set(memory_mb: 512).add(tags: ["prod"]).remove(env: ["OLD"]).apply
        #   inst.edit do |e|
        #     e.set(memory_mb: 512)
        #     e.remove(autokill: nil)
        #   end
        class Editor
          # @param what [String] the noun of the error message
          # @yieldparam items [Array<Hash>] the triples, on {#apply}
          def initialize(what, &commit)
            @what = what
            @commit = commit
            @items = []
          end

          # Replace these properties' values; nil removes the property.
          # @return [self]
          def set(**patch) = stage(patch, "set")

          # Merge into these properties, keeping what is already there.
          # @return [self]
          def add(**patch) = stage(patch, "add")

          # Remove members from these properties (`env: ["LOG_LEVEL"]`), or
          # the whole property with nil. The API calls this op `del`.
          # @return [self]
          def remove(**patch) = stage(patch, "del")

          # @return [Array<Hash>] the triples staged so far
          def changes = @items.dup.freeze

          # Send every staged change as one update.
          #
          # @return [Object] what the update returns: a handle, or an Array
          #   of them for a set
          # @raise [ArgumentError] when nothing was staged
          def apply
            if @items.empty?
              raise ArgumentError, "This #{@what} edit has no changes to apply; call set, add or " \
                                   "remove first."
            end

            @commit.call(changes)
          end

          # Values left out: any of them may be a secret (a token, credentials).
          def inspect
            staged = @items.map { |i| "#{i[:op]} #{i[:prop]}" }.join(", ")
            "#<#{self.class.name} #{@what} #{staged}>"
          end

          private

          def stage(patch, operation)
            @items.concat(Patch.items(patch, operation))
            self
          end
        end
      end
    end
  end
end
