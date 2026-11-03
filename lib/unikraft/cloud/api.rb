# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# The raw ("plumbing") layer of every Unikraft Cloud API, in one place.
# Everything here mirrors the OpenAPI specification: operations are named
# after their operationId, and responses come back as the untouched envelope.

require_relative "api/platform"
require_relative "api/controlplane"

module Unikraft
  module Cloud
    # Both raw API surfaces, as exposed by `ukc.api`.
    #
    # @example
    #   api = Unikraft::Cloud::API.new(
    #     platform: { base_url: "https://api.fra.unikraft.cloud", token: token },
    #     controlplane: { base_url: "https://api.unikraft.cloud", token: token }
    #   )
    #   api.platform.instances.get_instances(count: 10)
    #   api.controlplane.metros.list_metros
    class API
      # @return [Platform] the metro-scoped platform API
      attr_reader :platform
      # @return [ControlPlane] the global control-plane API
      attr_reader :controlplane

      # @param platform [Hash, #request] {Core::ApiClient} keywords, or a
      #   transport to use as is
      # @param controlplane [Hash, #request] likewise, for the control plane
      def initialize(platform:, controlplane:)
        @platform = build(Platform, platform)
        @controlplane = build(ControlPlane, controlplane)
      end

      private

      def build(klass, config)
        config.is_a?(Hash) ? klass.new(**config) : klass.new(config)
      end
    end
  end
end
