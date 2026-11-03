# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

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
      end
    end
  end
end
