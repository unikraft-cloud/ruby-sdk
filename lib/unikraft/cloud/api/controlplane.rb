# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require_relative "../core/http"
require_relative "controlplane/resources.gen"

module Unikraft
  module Cloud
    class API
      # Every control-plane API resource, raw. The control plane is global:
      # it lists metros, checks credentials and manages nodes.
      #
      # @example
      #   api = Unikraft::Cloud::API::ControlPlane.new(
      #     base_url: "https://api.unikraft.cloud", token: ENV["UKC_TOKEN"]
      #   )
      #   api.metros.list_metros.data.metros
      class ControlPlane
        # @return [#request, #bytes, #stream] the shared transport
        attr_reader :client
        # @return [AuthApi] authorization checks and sign-in
        attr_reader :auth
        # @return [ImagesApi] the global image registry
        attr_reader :images
        # @return [MetrosApi] the metros the account can reach
        attr_reader :metros
        # @return [NodeServiceApi] nodes
        attr_reader :nodes
        # @return [NodeActivationServiceApi] node activation and renewal
        attr_reader :node_activation

        # @param client [#request, #bytes, #stream, nil] a transport to share;
        #   when nil, one is built from `config`
        # @param config [Hash] {Core::ApiClient#initialize} keywords, e.g.
        #   `base_url:` and `token:`
        def initialize(client = nil, **config)
          @client = client || Core::ApiClient.new(**config)
          @auth = AuthApi.new(@client)
          @images = ImagesApi.new(@client)
          @metros = MetrosApi.new(@client)
          @nodes = NodeServiceApi.new(@client)
          @node_activation = NodeActivationServiceApi.new(@client)
        end
      end
    end
  end
end
