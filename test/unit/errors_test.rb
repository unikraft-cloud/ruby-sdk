# frozen_string_literal: true

require_relative "../test_helper"

class ErrorsTest < Minitest::Test
  Error = Unikraft::Cloud::Error

  def test_carries_kind_status_errors_and_body
    err = Error.new("nope", kind: :http, status: 404, errors: [{ status: 404 }], body: { a: 1 })

    assert_equal "nope", err.message
    assert_equal :http, err.kind
    assert_equal 404, err.status
    assert_equal [{ status: 404 }], err.errors
    assert_equal({ a: 1 }, err.body)
    assert_kind_of StandardError, err
  end

  def test_rejects_unknown_kind
    assert_raises(ArgumentError) { Error.new("x", kind: :bogus) }
  end

  def test_explicit_cause_wins
    inner = RuntimeError.new("inner")
    err = Error.new("outer", kind: :timeout, cause: inner)

    assert_same inner, err.cause
  end

  def test_implicit_cause_is_kept
    err = assert_raises(Error) do
      raise "inner"
    rescue RuntimeError
      raise Error.new("outer", kind: :network)
    end

    assert_equal "inner", err.cause.message
  end

  def test_fanout_error_surfaces_a_shared_status
    a = Error.new("a", kind: :http, status: 403)
    b = Error.new("b", kind: :http, status: 403)
    err = Unikraft::Cloud::MetroFanoutError.new(
      "2 of 3 metros failed",
      failures: [{ metro: "fra", error: a }, { metro: "sin", error: b }], results: [1]
    )

    assert_equal :fanout, err.kind
    assert_equal 403, err.status
    assert_same a, err.cause
    assert_equal [1], err.results
    assert_kind_of Error, err
  end

  def test_fanout_error_drops_mixed_statuses
    failures = [
      { metro: "fra", error: Error.new("a", kind: :http, status: 403) },
      { metro: "sin", error: Error.new("b", kind: :network) }
    ]

    assert_nil Unikraft::Cloud::MetroFanoutError.new("x", failures: failures).status
  end

  def test_ambiguous_ref_error_lists_metros
    match = Struct.new(:metro)
    err = Unikraft::Cloud::AmbiguousRefError.new("ambiguous",
                                                 matches: [match.new("fra"), match.new("sin")])

    assert_equal %w[fra sin], err.metros
    assert_equal :fanout, err.kind
  end
end
