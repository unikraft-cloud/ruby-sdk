# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require "json"

module Unikraft
  module Cloud
    # Base class of every generated model: a read-only view over a JSON
    # object with one reader per declared property.
    #
    # A model is built from a Hash with symbol or string keys. Every field is
    # optional (a reader returns nil for a missing key) and unknown keys are
    # kept, so a newer server never breaks an older SDK: they stay reachable
    # through {#[]} and {#to_h}. Nested objects become their declared model
    # class, recursively.
    #
    # @example
    #   class Instance < Unikraft::Cloud::Model
    #     attribute :name
    #   end
    #   inst = Instance.new(name: "web", extra: 1)
    #   inst.name      # => "web"
    #   inst[:extra]   # => 1
    #   inst.to_h      # => { name: "web", extra: 1 }
    class Model
      # Fields {#inspect} masks: keys, tokens and credentials the API returns.
      REDACTED = %i[authorization credentials pkey secret token].freeze
      MASK = Object.new.tap { |o| o.define_singleton_method(:inspect) { "[REDACTED]" } }.freeze
      private_constant :MASK

      class << self
        # @return [Hash{Symbol => Array}] the declared properties, by wire key
        def attributes
          @attributes ||= superclass <= Model ? superclass.attributes.dup : {}
        end

        # Declare a property and define its reader.
        #
        # @param name [Symbol] the reader, and the wire key unless `key:` is given
        # @param type [String, Class, nil] the model class of the value, by
        #   constant name relative to this class's namespace; nil for scalars
        # @param array [Boolean] the value is an array of `type`
        # @param map [Boolean] the value is an object whose values are `type`
        # @param key [Symbol] the wire key, when it is no valid reader name
        def attribute(name, type = nil, array: false, map: false, key: name)
          attributes[key.to_sym] = [type, array, map].freeze
          # A reader the base class already defines (`metro`) keeps its own.
          return if Model.method_defined?(name)

          define_method(name) { @values[key.to_sym] }
        end

        # Build a model from a Hash, pass a model or nil through.
        #
        # @param value [Hash, Model, nil]
        # @return [Model, nil]
        def from(value)
          value.nil? || value.is_a?(self) ? value : new(value)
        end
      end

      # @param values [Hash, Model] the JSON object
      def initialize(values = {})
        values = values.to_h unless values.is_a?(Hash)
        @values = values.to_h do |k, v|
          key = k.to_sym
          [key, cast(self.class.attributes[key], v)]
        end.freeze
        @metro = nil
      end

      # Read a field by its wire key, declared or not.
      #
      # @param key [Symbol, String]
      def [](key)
        @values[key.to_sym]
      end

      # The metro this model was read from, when the porcelain tagged it (see
      # {#with_metro}), or else its own `metro` field.
      #
      # @return [String, nil]
      def metro
        @metro || @values[:metro]
      end

      # A copy tagged with the metro it came from. The tag is not part of
      # {#to_h}, so it never reaches the wire.
      #
      # @param metro [String]
      # @return [Model]
      def with_metro(metro)
        copy = dup
        copy.instance_variable_set(:@metro, metro)
        copy
      end

      # The JSON object, nested models included, with symbol keys.
      #
      # @return [Hash]
      def to_h
        @values.transform_values { |v| plain(v) }
      end

      # Pattern matching on the fields, and on the `metro` tag when set.
      #
      # @example
      #   case inst
      #   in { state: "running", metro: "fra" } then ...
      #   end
      def deconstruct_keys(_keys)
        @metro ? @values.merge(metro: @metro) : @values
      end

      # @return [String]
      def to_json(*)
        to_h.to_json(*)
      end

      def ==(other)
        other.instance_of?(self.class) && other.to_h == to_h && other.metro == metro
      end
      alias eql? ==

      def hash
        [self.class, to_h, metro].hash
      end

      def inspect = "#<#{self.class.name || "Model"} #{inspect_fields}>"
      alias to_s inspect

      # The fields as {#inspect} shows them, secrets ({REDACTED}) masked at
      # any depth, untyped Hashes included.
      #
      # @api private
      # @return [String]
      def inspect_fields
        fields = redact(@values).map { |k, v| "#{k}=#{v.inspect}" }
        fields << "metro=#{@metro.inspect}" if @metro
        fields.join(", ")
      end

      private

      def cast(spec, value)
        type, array, map = spec
        return value if type.nil? || value.nil?

        klass = resolve(type)
        if array && value.is_a?(Array)
          value.map { |v| cast_one(klass, v) }
        elsif map && value.is_a?(Hash)
          value.transform_values { |v| cast_one(klass, v) }
        else
          cast_one(klass, value)
        end
      end

      # Anything other than an object (a newer server's shape) is kept as is.
      def cast_one(klass, value)
        value.is_a?(Hash) ? klass.new(value) : value
      end

      def resolve(type)
        return type if type.is_a?(Class)

        namespace = self.class.name.to_s.rpartition("::").first
        Object.const_get(namespace.empty? ? type : "#{namespace}::#{type}")
      end

      def redact(value)
        case value
        when Hash then value.to_h { |k, v| [k, secret?(k) ? MASK : redact(v)] }
        when Array then value.map { |v| redact(v) }
        else value
        end
      end

      # HTTP headers come in any case, e.g. `Authorization`.
      def secret?(key) = REDACTED.include?(key.to_s.downcase.to_sym)

      def plain(value)
        case value
        when Model then value.to_h
        when Array then value.map { |v| plain(v) }
        when Hash then value.transform_values { |v| plain(v) }
        else value
        end
      end
    end
  end
end
