# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fake_cloud"

class VolumesTest < Minitest::Test
  include FakeCloud::Helpers

  def volume = ok(volumes: [{ uuid: "v1", name: "data", size_mb: 1024 }])

  def test_attach_chains_off_a_get_in_one_request
    ukc = client(metro: :fra) { volume }
    ukc.volumes.get(name: "data").attach(attach_to: { name: "web" }, at: "/data")

    assert_equal ["/v1/volumes/attach"], @cloud.paths
    assert_equal [{ "name" => "data", "attach_to" => { "name" => "web" }, "at" => "/data" }],
                 @cloud.calls.first.body
  end

  def test_detach_shorthand
    ukc = client(metro: :fra) { volume }
    ukc.volumes.detach(name: "data", from: { name: "web" }, timeout: 5)

    assert_equal [{ "name" => "data", "from" => { "name" => "web" } }], @cloud.calls.first.body
    assert_equal 5, @cloud.calls.first.options[:timeout]
  end

  def test_instance_refs_reach_the_wire_as_identifiers
    ukc = client(metro: :fra) { volume }
    ref = Unikraft::Cloud::Core::Ref.new(uuid: "i1", metro: :fra)
    ukc.volumes.get(name: "data").attach(attach_to: ref, at: "/data")
    ukc.volumes.detach(name: "data", from: { "name" => "web", "metro" => "fra" })

    assert_equal({ "uuid" => "i1" }, @cloud.calls[0].body.first["attach_to"])
    assert_equal({ "name" => "web" }, @cloud.calls[1].body.first["from"])
  end

  def test_a_url_metro_matches_with_or_without_v1
    url = "https://api.staging.internal/v1"
    ukc = client(metro: url) { volume }
    ukc.volumes.get(name: "data").attach(attach_to: { name: "web", metro: url }, at: "/d")

    assert_equal({ "name" => "web" }, @cloud.calls.first.body.first["attach_to"])
  end

  def test_an_instance_in_another_metro_is_refused
    ukc = client(metro: :fra) { volume }
    data = ukc.volumes.get(name: "data")

    assert_raises(ArgumentError) { data.attach(attach_to: { name: "web", metro: :dal }, at: "/d") }
    assert_raises(ArgumentError) { data.detach(from: { name: "web", metro: :dal }) }
    assert_empty @cloud.calls
  end

  def test_update_and_attributes
    ukc = client(metro: :fra) { volume }
    ukc.volumes.get(name: "data").update(size_mb: 2048)

    assert_equal [{ "name" => "data", "prop" => "size_mb", "op" => "set", "value" => 2048 }],
                 @cloud.calls.first.body
    assert_equal 1024, ukc.volumes.get(name: "data").size_mb
  end

  def test_a_qualified_ref_goes_straight_to_its_metro
    ukc = client { volume }
    ukc.volumes.get(name: "data", metro: :sin).update(size_mb: 4096)

    assert_equal ["api.sin.unikraft.cloud"], @cloud.calls.map(&:host)
    refute @cloud.calls.first.body.first.key?("metro")
  end

  def test_list_and_where
    ukc = everywhere(%i[fra dal], key: :volumes)

    assert_equal %w[dal fra], ukc.volumes.map(&:metro).sort
    assert_equal 2, ukc.volumes.where(name: "web").detach.size
  end
end
