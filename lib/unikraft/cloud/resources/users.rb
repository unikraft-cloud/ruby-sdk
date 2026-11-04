# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require_relative "../core/resource"
require_relative "../api/platform"

module Unikraft
  module Cloud
    module Resources
      # Users and quotas. Quotas are per metro, so reading them fans out
      # across the scope and tags each entry with its metro.
      class Users < Core::Scoped
        API_CLASS = API::Platform::UsersApi

        # The quotas of the authenticated user, or of the user `uuid`, in
        # every metro in scope.
        #
        # @example
        #   ukc.users.quotas.each { |q| puts "#{q.metro} #{q.used.inspect}" }
        # @param uuid [String, nil]
        # @param opts [Hash] `metros:`, `base_url:`, `headers:`, `timeout:`
        # @return [Array<Model>]
        def quotas(uuid: nil, **opts)
          endpoints = endpoints(check_options!(opts))
          read = lambda do |endpoint|
            call = call_options(endpoint, opts)
            res = uuid ? api.get_user_by_uuid(uuid:, **call) : api.get_user(**call)
            Core::Response.list(res, :quotas).map { |q| q.with_metro(endpoint.metro) }
          end
          return read.call(endpoints.first) if endpoints.size == 1

          Core::Fanout.all(endpoints, flat: true, &read)
        end
      end
    end
  end
end
