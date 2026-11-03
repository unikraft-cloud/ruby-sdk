# frozen_string_literal: true

require_relative "../test_helper"

class Base64Test < Minitest::Test
  B64 = Unikraft::Cloud::Core::Base64

  def test_round_trips_binary
    bytes = (0..255).to_a.pack("C*")

    assert_equal bytes, B64.decode(B64.encode(bytes))
    refute_includes B64.encode(bytes * 4), "\n"
  end

  def test_decode_text_is_utf8
    assert_equal "héllo", B64.decode_text(B64.encode("héllo"))
  end

  def test_rejects_non_strict_input
    assert_raises(ArgumentError) { B64.decode("a b") }
  end

  def test_strips_trailing_slashes
    assert_equal "https://x", Unikraft::Cloud::Core::URL.strip_trailing_slashes("https://x///")
  end
end
