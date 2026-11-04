# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fake_cloud"

class UsersTest < Minitest::Test
  include FakeCloud::Helpers

  def test_quotas_are_tagged_with_their_metro
    ukc = client(metro: :fra) { ok(quotas: [{ uuid: "q1" }]) }
    quotas = ukc.users.quotas

    assert_equal([%w[q1 fra]], quotas.map { |q| [q.uuid, q.metro] })
    assert_equal "/v1/users/quotas", @cloud.paths.last
    ukc.users.quotas(uuid: "u1")

    assert_equal "/v1/users/u1/quotas", @cloud.paths.last
  end

  def test_quotas_merge_every_metro
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal) if call.path == "/v1/metros"

      ok(quotas: [{ uuid: "q-#{call.metro}" }])
    end

    assert_equal %w[dal:q-dal fra:q-fra], ukc.users.quotas.map { |q| "#{q.metro}:#{q.uuid}" }.sort
  end

  def test_quotas_report_failed_metros
    ukc = client do |call|
      next FakeCloud.failure(503) if call.metro == "dal"

      ok(quotas: [{ uuid: "q" }])
    end
    err = assert_raises(Unikraft::Cloud::MetroFanoutError) { ukc.users.quotas(metros: %i[fra dal]) }

    assert_equal ["fra"], err.results.map(&:metro)
  end
end
