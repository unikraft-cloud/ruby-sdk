# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

module Unikraft
  module Cloud
    module Core
      # Strict base64, the way the plugins carry binary payloads. Built on
      # `pack("m0")` because the `base64` library left the default gems in
      # Ruby 3.4, and the SDK takes no runtime dependencies.
      module Base64
        module_function

        # @param bytes [String] any encoding; its bytes are encoded
        # @return [String] strict (unwrapped) base64
        def encode(bytes)
          [bytes.to_s.b].pack("m0")
        end

        # @param text [String] strict base64
        # @return [String] the decoded bytes, as binary
        # @raise [ArgumentError] when the input is not strict base64
        def decode(text)
          text.to_s.unpack1("m0")
        end

        # @param text [String] strict base64 of UTF-8 text
        # @return [String] the decoded text, as UTF-8
        def decode_text(text)
          decode(text).force_encoding(Encoding::UTF_8)
        end
      end
    end
  end
end
