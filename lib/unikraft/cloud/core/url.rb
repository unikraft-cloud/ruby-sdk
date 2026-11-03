# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require "uri"

module Unikraft
  module Cloud
    module Core
      # Small URL helpers shared by the transport and the metro resolution.
      module URL
        module_function

        # Remove every trailing "/" from a URL.
        #
        # @param url [String]
        # @return [String]
        def strip_trailing_slashes(url)
          url.to_s.sub(%r{/+\z}, "")
        end

        # Percent-encode one path segment, so a value with a `/`, `?` or `#`
        # in it cannot change the path or start a query.
        #
        # @param value [#to_s]
        # @return [String]
        def escape_segment(value)
          URI.encode_www_form_component(value.to_s).gsub("+", "%20")
        end
      end
    end
  end
end
