# frozen_string_literal: true

require_relative "../test_helper"
require "pp"
require_relative "../support/fake_cloud"

class ClientTest < Minitest::Test
  include FakeCloud::Helpers

  def test_new_builds_a_client
    ukc = client(metro: :dal) { ok }

    assert_kind_of Unikraft::Cloud::Client, ukc
    assert_equal %w[dal], ukc.scope
    assert_equal "t", @cloud.transports.first.config[:token]
  end

  def test_reads_token_and_metro_from_the_environment
    ENV["UKC_TOKEN"] = "from-env"
    ENV["UKC_METRO"] = "sin"
    cloud = FakeCloud.new { ok }
    ukc = Unikraft::Cloud.new(transport: cloud.transport)

    assert_equal %w[sin], ukc.scope
    assert_equal "from-env", cloud.transports.first.config[:token]
    assert_equal "https://api.sin.unikraft.cloud", cloud.transports.first.base_url
  end

  def test_scope_precedence
    assert_equal :all, client { ok }.scope
    assert_equal %w[fra dal], client(metro: :sin, metros: %i[fra dal]).scope
    assert_equal :all, client(metro: :sin, metros: :all).scope
    assert_equal %w[fra dal], client { ok }.metros(:fra, "dal").scope
    assert_equal :all, client { ok }.metros(:all).scope
  end

  def test_raw_layers
    ukc = client(metro: :fra) { ok(instances: [{ uuid: "u1" }]) }
    res = ukc.api.platform.instances.get_instances(count: 10)

    assert_equal "success", res.status
    assert_equal "https://api.fra.unikraft.cloud", @cloud.calls.last.base_url
    ukc.api.controlplane.metros.list_metros

    assert_equal "https://controlplane.unikraft.cloud/v1/metros", @cloud.calls.last.url
    ukc.metro(:dal).api.platform.instances.get_instances

    assert_equal "https://api.dal.unikraft.cloud", @cloud.calls.last.base_url
  end

  def test_metro_scopes_are_cached
    ukc = client { ok }

    assert_same ukc.metro(:fra), ukc.metro("fra")
    refute_same ukc.metro(:fra), ukc.metro(:dal)
    assert_equal "fra", ukc.metro(:fra).endpoint.metro
  end

  def test_available_metros
    ukc = client { FakeCloud.metros(:fra, :dal) }

    assert_equal([%w[fra https://api.fra.unikraft.cloud], %w[dal https://api.dal.unikraft.cloud]],
                 ukc.available_metros.map { |m| [m.metro, m.base_url] })
    assert_equal %w[fra dal sin was sfo], Unikraft::Cloud::KNOWN_METROS
  end

  def test_a_url_metro_is_used_verbatim_and_never_discovers
    ukc = client(metro: "https://api.staging.internal/v1",
                 control_plane_url: "https://cp.staging.internal") { ok }

    assert_equal ["https://api.staging.internal"], ukc.available_metros.map(&:base_url)
    assert_equal "https://api.staging.internal", ukc.metro(:dal).endpoint.base_url

    assert_empty @cloud.calls
    ukc.api.controlplane.metros.list_metros

    assert_equal "https://cp.staging.internal", @cloud.calls.last.base_url
  end

  def test_close_and_open
    ukc = client { FakeCloud.metros(:fra) }
    ukc.available_metros
    ukc.close

    assert_includes @cloud.closed, "https://controlplane.unikraft.cloud"
    cloud = FakeCloud.new { ok }
    value = Unikraft::Cloud.open(token: "t", metro: :fra, transport: cloud.transport) do |c|
      c.api.platform.instances.get_instances
      :done
    end

    assert_equal :done, value
    assert_equal ["https://api.fra.unikraft.cloud", "https://controlplane.unikraft.cloud"],
                 cloud.closed.sort
  end

  def test_inspect_hides_the_token
    refute_includes client(token: "secret") { ok }.inspect, "secret"
    ukc = Unikraft::Cloud.new(token: "secret", metro: :fra, headers: { "X-Key" => "hidden" })

    [ukc, ukc.api, ukc.api.platform.instances, ukc.metro(:dal).api].each do |object|
      refute_includes object.inspect, "secret"
      refute_includes PP.pp(object, +""), "secret"
      refute_includes object.inspect, "hidden"
    end
  end
end
