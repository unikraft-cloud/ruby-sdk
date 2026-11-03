# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require_relative "../core/http"
require_relative "platform/resources.gen"

module Unikraft
  module Cloud
    class API
      # Every platform API resource, raw. The platform API is metro-scoped:
      # these clients talk to the one metro their `base_url` names, and a
      # single call can be redirected with `base_url:`. Fanning out across
      # metros is the porcelain's job.
      #
      # @example
      #   api = Unikraft::Cloud::API::Platform.new(
      #     base_url: "https://api.fra.unikraft.cloud", token: ENV["UKC_TOKEN"]
      #   )
      #   res = api.instances.get_instances(count: 10, details: true)
      #   res.data.instances
      class Platform
        # @return [#request, #bytes, #stream] the shared transport
        attr_reader :client
        # @return [AuditApi] the audit event stream
        attr_reader :audit
        # @return [AutoscaleApi] autoscale configurations and policies
        attr_reader :autoscale
        # @return [CertificatesApi] TLS certificates
        attr_reader :certificates
        # @return [ImagesApi] the image registry (metro-scoped view)
        attr_reader :images
        # @return [InstancesApi] instances (microVMs)
        attr_reader :instances
        # @return [NodeApi] metro node information
        attr_reader :node
        # @return [ServicesApi] service groups (load-balanced networking)
        attr_reader :services
        # @return [UsersApi] users and quotas
        attr_reader :users
        # @return [VolumesApi] persistent volumes
        attr_reader :volumes

        # @param client [#request, #bytes, #stream, nil] a transport to share;
        #   when nil, one is built from `config`
        # @param config [Hash] {Core::ApiClient#initialize} keywords, e.g.
        #   `base_url:` and `token:`
        def initialize(client = nil, **config)
          @client = client || Core::ApiClient.new(**config)
          @audit = AuditApi.new(@client)
          @autoscale = AutoscaleApi.new(@client)
          @certificates = CertificatesApi.new(@client)
          @images = ImagesApi.new(@client)
          @instances = InstancesApi.new(@client)
          @node = NodeApi.new(@client)
          @services = ServicesApi.new(@client)
          @users = UsersApi.new(@client)
          @volumes = VolumesApi.new(@client)
        end
      end
    end
  end
end
