# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

module Unikraft
  module Cloud
    module Core
      # A reference to one resource: a `name` or a `uuid`, never both.
      #
      # The API validates every identifier it is given, so a name sent in the
      # `uuid` filter fails with `Invalid uuid '<name>'`: the ref states which
      # kind it holds, and only that field is sent. A name is unique only
      # within a metro, so it can be qualified with `metro`, which also saves
      # a lookup. A uuid identifies one resource wherever it lives.
      #
      # @example
      #   Ref.new(name: "web")
      #   Ref.new(name: "web", metro: :fra)
      #   Ref.coerce({ uuid: "550e8400-e29b-41d4-a716-446655440000" })
      #   case ref
      #   in { name: String => name, metro: nil } then ...
      #   end
      Ref = Data.define(:name, :uuid, :metro) do
        # @raise [ArgumentError] when given both or neither of name and uuid
        def initialize(name: nil, uuid: nil, metro: nil)
          raise ArgumentError, "a ref takes `name:` or `uuid:`, not both" if name && uuid
          raise ArgumentError, "a ref needs `name:` or `uuid:`" if name.nil? && uuid.nil?

          super(name: name&.to_s, uuid: uuid&.to_s, metro: metro&.to_s)
        end

        # @param value [Ref, Hash] a ref, or a Hash with `:name` or `:uuid`
        #   and optionally `:metro` (Symbol or String keys)
        # @return [Ref]
        def self.coerce(value)
          return value if value.is_a?(Ref)
          unless value.is_a?(Hash)
            raise ArgumentError,
                  "a ref is a Hash with `name:` or `uuid:`, got #{value.inspect}"
          end

          fields = value.transform_keys(&:to_sym)
          unknown = fields.keys - members
          raise ArgumentError, "unknown ref key(s): #{unknown.join(", ")}" unless unknown.empty?

          new(**fields)
        end

        # One ref or an Array of them, as an Array.
        #
        # @param value [Ref, Hash, Array<Ref, Hash>]
        # @return [Array<Ref>]
        def self.list(value)
          refs = value.is_a?(Array) ? value.map { |v| coerce(v) } : [coerce(value)]
          raise ArgumentError, "no refs given" if refs.empty?

          refs
        end

        # The ref as a request body carries it: the identifier alone. `metro`
        # says where to send the request and must not reach the wire.
        #
        # @return [Hash]
        def wire
          uuid ? { uuid: } : { name: }
        end

        # The ref as a query filter.
        #
        # @return [Hash]
        def query
          uuid ? { uuid: [uuid] } : { name: [name] }
        end

        # @return [String] e.g. `name "web" in fra`
        def to_s
          id = uuid ? %(uuid "#{uuid}") : %(name "#{name}")
          metro ? "#{id} in #{metro}" : id
        end
      end

      # Where a handle's resource lives: the ref, and the metro and base URL
      # serving it.
      #
      # @!attribute [r] ref
      #   @return [Ref] qualified with the metro
      # @!attribute [r] metro
      #   @return [String]
      # @!attribute [r] base_url
      #   @return [String]
      Location = Data.define(:ref, :metro, :base_url)
    end
  end
end
