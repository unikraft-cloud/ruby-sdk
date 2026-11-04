# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require_relative "../core/resource"
require_relative "../api/platform"

module Unikraft
  module Cloud
    module Resources
      # A handle on one service group (see {Core::Handle}): `update`, `edit`
      # and `delete`.
      #
      # @example
      #   ukc.services.get(name: "web").update(soft_limit: 5, hard_limit: 20)
      #   ukc.services.edit(name: "web") { |e| e.remove(domains: nil) }
      class ServiceGroupHandle < Core::Handle
        attributes_of API::Platform::Models::ServiceGroup
      end

      # Every service group matching one ref, one per metro.
      class ServiceGroupSet < Core::HandleSet; end

      # Service groups (load-balanced networking), as `ukc.services`.
      class ServiceGroups < Core::Resource
        API_CLASS = API::Platform::ServicesApi
        HANDLE = ServiceGroupHandle
        SET = ServiceGroupSet
        SPEC = Spec.new(noun: "service group", key: :service_groups, list: :get_service_groups,
                        create: :create_service_group, delete: :delete_service_groups,
                        update: :update_service_groups)
      end
    end
  end
end
