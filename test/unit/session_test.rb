# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fake_cloud"

class SessionTest < Minitest::Test
  Core = Unikraft::Cloud::Core

  def session(cloud, **overrides)
    Core::Session.new(config: { token: "t" }, platform_url: "https://api.fra.unikraft.cloud",
                      controlplane_url: Unikraft::Cloud::CONTROLPLANE_BASE_URL,
                      default_metro: "fra", transport: cloud.transport, **overrides)
  end

  def test_discovers_once_across_threads
    cloud = FakeCloud.new { FakeCloud.metros(:fra, :dal) }
    s = session(cloud)

    results = Array.new(8) { Thread.new { s.discover.map(&:metro) } }.map(&:value)

    assert_equal [%w[fra dal]], results.uniq
    assert_equal ["/v1/metros"], cloud.paths
    assert_equal "https://controlplane.unikraft.cloud", cloud.calls.first.base_url
  end

  def test_trusts_the_reported_endpoint
    cloud = FakeCloud.new do
      FakeCloud.ok(metros: [{ iata_code: "stg", endpoint: "https://api.stg.example/v1" }])
    end
    s = session(cloud)

    assert_equal [Core::Endpoint.new(metro: "stg", base_url: "https://api.stg.example")], s.discover
    assert_equal "https://api.stg.example", s.endpoint_for(:stg).base_url
  end

  def test_a_failed_discovery_is_not_cached
    answers = [FakeCloud.failure(500), FakeCloud.metros(:fra)]
    cloud = FakeCloud.new { answers.shift }
    s = session(cloud)

    err = assert_raises(Unikraft::Cloud::Error) { s.discover }

    assert_match(/Could not discover/, err.message)
    assert_equal :fanout, err.kind
    assert_equal 500, err.cause.status
    assert_equal ["fra"], s.discover.map(&:metro)
  end

  def test_a_named_scope_never_discovers
    cloud = FakeCloud.new { flunk "no request expected" }
    s = session(cloud)

    assert_equal %w[https://api.fra.unikraft.cloud https://api.dal.unikraft.cloud],
                 s.resolve(%w[fra dal]).map(&:base_url)
    assert_equal "fra", s.resolve_one(:all, "Creating").metro
    assert_raises(Unikraft::Cloud::Error) { s.resolve([]) }
  end

  def test_one_endpoint_falls_back_to_the_default_metro
    s = session(FakeCloud.new { flunk "no request expected" })

    assert_equal "fra", s.resolve_one(:all, "Creating").metro
    assert_equal "fra", s.resolve_one(%w[dal fra], "Creating").metro
    assert_equal "dal", s.resolve_one(%w[dal], "Creating").metro
    err = assert_raises(Unikraft::Cloud::Error) { s.resolve_one(%w[sin dal], "Creating an instance") }

    assert_equal :config, err.kind
    assert_match(/targets a single metro.*leaves out the default metro \(fra\)/, err.message)
  end

  def test_a_pinned_endpoint_is_the_only_one
    cloud = FakeCloud.new { flunk "no request expected" }
    s = session(cloud, pinned: true)

    assert_equal [s.pinned], s.resolve(:all)
    assert_equal [s.pinned], s.discover
    assert_equal s.pinned, s.endpoint_for(:dal)
    assert_equal s.pinned, s.resolve_one(%w[fra dal], "Creating")
  end

  def test_close_closes_every_transport
    cloud = FakeCloud.new { FakeCloud.metros(:fra) }
    s = session(cloud)
    s.transport
    s.discover
    s.close
    s.close

    assert_equal 2, cloud.transports.size
    assert_includes cloud.closed, "https://controlplane.unikraft.cloud"
    refute_includes s.inspect, "t\""
  end
end
