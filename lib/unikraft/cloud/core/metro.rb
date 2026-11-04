# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require_relative "url"
require_relative "errors"

module Unikraft
  module Cloud
    # The metros known when this version was published. Any other code works
    # too: discovery trusts the control plane, so new metros need no upgrade.
    KNOWN_METROS = %w[fra dal sin was sfo].freeze

    # The metro an operation that must pick one (such as `create`) uses when
    # neither `metro:` nor `UKC_METRO` names one.
    DEFAULT_METRO = "fra"

    # The global control-plane API. Unlike the platform API it has no metro.
    CONTROLPLANE_BASE_URL = "https://controlplane.unikraft.cloud"

    module Core
      # A metro paired with the platform API base URL that serves it.
      #
      # @!attribute [r] metro
      #   @return [String] the metro code, or the base URL itself for an
      #     explicitly named endpoint
      # @!attribute [r] base_url
      #   @return [String]
      Endpoint = Data.define(:metro, :base_url)

      # Turning metro codes, URLs and scopes into endpoints.
      module Metro
        module_function

        # @param metro [String, Symbol]
        # @return [Boolean] whether the value is an `http(s)://` URL
        def url?(metro)
          metro.to_s.match?(%r{\Ahttps?://}i)
        end

        # The platform API base URL of a metro: `fra` becomes
        # `https://api.fra.unikraft.cloud`. A URL is used verbatim, minus
        # trailing slashes and a trailing `/v1`, which every operation path
        # already carries.
        #
        # @param metro [String, Symbol]
        # @return [String]
        def base_url(metro)
          return "https://api.#{metro}.unikraft.cloud" unless url?(metro)

          URL.strip_trailing_slashes(metro).sub(%r{/v1\z}, "")
        end

        # @param metro [String, Symbol]
        # @return [Endpoint]
        def endpoint(metro)
          Endpoint.new(metro: metro.to_s, base_url: base_url(metro))
        end

        # Normalise a scope: `:all` (or `"all"`), one metro, or a list of them,
        # as Symbols or Strings.
        #
        # @param scope [Symbol, String, Array<Symbol, String>]
        # @return [:all, Array<String>]
        def scope(scope)
          list = Array(scope).flatten
          return :all if list.size == 1 && list.first.to_s == "all"

          list.map(&:to_s).uniq.freeze
        end
      end
    end
  end
end
