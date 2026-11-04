# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fake_cloud"

class CertificatesTest < Minitest::Test
  include FakeCloud::Helpers

  def cert = ok(certificates: [{ uuid: "c1", name: "star", common_name: "*.example.com" }])

  def test_update_replaces_chain_and_key
    ukc = client(metro: :fra) { cert }
    ukc.certificates.update(name: "star", chain: "PEM", pkey: "KEY")

    assert_equal ["/v1/certificates"], @cloud.paths
    assert_equal %w[PUT], @cloud.verbs
    assert_equal [{ "name" => "star", "chain" => "PEM", "pkey" => "KEY" }], @cloud.calls.first.body
    refute_respond_to ukc.certificates.get(name: "star"), :edit
  end

  def test_inspect_redacts_the_private_key
    ukc = client(metro: :fra) { ok(certificates: [{ name: "star", pkey: "KEY" }]) }
    handle = ukc.certificates.get(name: "star")
    handle.model

    [handle.inspect, handle.model.inspect, handle.to_s].each do |s|
      refute_includes s, "KEY"
      assert_includes s, "pkey=[REDACTED]"
    end
  end

  def test_inspect_redacts_nested_untyped_secrets
    model = Unikraft::Cloud::Model.new(config: { "registry" => [{ "token" => "TOK" }] })

    refute_includes model.inspect, "TOK"
    assert_match(/"token" ?=> ?\[REDACTED\]/, model.inspect) # spacing differs before 3.4
    refute_includes Unikraft::Cloud::Model.new(headers: { "Authorization" => "B" }).inspect, '"B"'
  end

  def test_delete_and_read
    ukc = client { cert }
    ukc.certificates.get(name: "star", metro: :sfo).delete

    assert_equal ["https://api.sfo.unikraft.cloud/v1/certificates"], @cloud.calls.map(&:url)
    assert_equal "*.example.com", ukc.certificates.get(name: "star", metro: :fra).common_name
  end
end
