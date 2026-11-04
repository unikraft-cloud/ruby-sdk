# frozen_string_literal: true

require_relative "../test_helper"

class RefTest < Minitest::Test
  Core = Unikraft::Cloud::Core
  Models = Unikraft::Cloud::API::Platform::Models

  def test_metro_base_url
    assert_equal "https://api.fra.unikraft.cloud", Core::Metro.base_url(:fra)
    assert_equal "https://api.staging.internal", Core::Metro.base_url("https://api.staging.internal")
    # Every operation path carries /v1, so a trailing one is dropped.
    assert_equal "https://api.staging.internal",
                 Core::Metro.base_url("https://api.staging.internal/v1/")
  end

  def test_scope_accepts_symbols_and_strings
    assert_equal :all, Core::Metro.scope(:all)
    assert_equal :all, Core::Metro.scope("all")
    assert_equal %w[fra], Core::Metro.scope(:fra)
    assert_equal %w[fra dal], Core::Metro.scope([:fra, "dal"])
  end

  def test_ref_states_one_identifier
    assert_raises(ArgumentError) { Core::Ref.new(name: "a", uuid: "b") }
    assert_raises(ArgumentError) { Core::Ref.new }
    assert_raises(ArgumentError) { Core::Ref.coerce("web") }
    assert_raises(ArgumentError) { Core::Ref.coerce({ nme: "web" }) }
  end

  def test_ref_keeps_metro_off_the_wire
    ref = Core::Ref.coerce({ "name" => "web", "metro" => :fra })

    assert_equal "fra", ref.metro
    assert_equal({ name: "web" }, ref.wire)
    assert_equal({ name: ["web"] }, ref.query)
    assert_equal 'name "web" in fra', ref.to_s
    assert_equal({ uuid: ["u1"] }, Core::Ref.new(uuid: "u1").query)
  end

  def test_ref_list
    assert_equal 2, Core::Ref.list([{ name: "a" }, { uuid: "b" }]).size
    assert_equal 1, Core::Ref.list({ name: "a" }).size
    assert_raises(ArgumentError) { Core::Ref.list([]) }
  end

  def test_refs_and_models_pattern_match
    matched = case Core::Ref.new(name: "web", metro: :fra)
              in { name:, metro: "fra" } then name
              end

    assert_equal "web", matched
    inst = Models::Instance.new(name: "web", state: "running").with_metro("dal")

    assert_pattern { inst => { state: "running", metro: "dal" } }
  end

  def envelope(body)
    Models::GetInstancesResponse.new(body)
  end

  def test_unwrap_returns_data
    res = envelope(status: "success", data: { instances: [{ name: "web" }] })

    assert_equal "web", Core::Response.first(res, :instances, "instance").name
    assert_empty Core::Response.list(envelope(status: "success"), :instances)
  end

  def test_unwrap_raises_on_a_reported_error
    err = assert_raises(Unikraft::Cloud::Error) do
      Core::Response.list(envelope(status: "error", message: "nope", errors: [{ status: 500 }]),
                          :instances)
    end

    assert_equal 500, err.status
    assert_equal "nope", err.message
  end

  def test_unwrap_reads_a_per_entry_failure
    res = envelope(status: "error", message: "Failed to perform all operations",
                   data: { instances: [{ status: "error", error: 8,
                                         message: "No instance with uuid 'u1'" }] })
    err = assert_raises(Unikraft::Cloud::Error) { Core::Response.list(res, :instances) }

    assert_equal 404, err.status
    assert_equal "No instance with uuid 'u1'", err.message
    assert_nil(Core::Response.absent { Core::Response.list(res, :instances) })
  end

  def test_partial_success_is_returned
    res = envelope(status: "partial_success",
                   data: { instances: [{ name: "a" }, { status: "error", error: 8 }] })

    assert_equal 2, Core::Response.list(res, :instances).size
  end

  def test_first_raises_a_later_failed_entry
    res = envelope(status: "partial_success",
                   data: { instances: [{ name: "a" }, { status: "error", message: "bad prop" }] })
    err = assert_raises(Unikraft::Cloud::Error) { Core::Response.first(res, :instances, "instance") }

    assert_equal "bad prop", err.message
  end

  def test_first_raises_a_failed_partial_success_entry
    res = envelope(status: "partial_success",
                   data: { instances: [{ status: "error", error: 8, message: "gone" }] })
    err = assert_raises(Unikraft::Cloud::Error) { Core::Response.first(res, :instances, "instance") }

    assert_equal 404, err.status
    assert_equal "gone", err.message
  end

  def test_first_raises_not_found
    err = assert_raises(Unikraft::Cloud::Error) do
      Core::Response.first(envelope(status: "success", data: { instances: [] }), :instances,
                           "instance")
    end

    assert_equal 404, err.status
  end
end
