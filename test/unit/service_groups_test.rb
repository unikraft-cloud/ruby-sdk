# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fake_cloud"

class ServiceGroupsTest < Minitest::Test
  include FakeCloud::Helpers

  def group = ok(service_groups: [{ uuid: "sg1", name: "web", hard_limit: 10 }])

  def test_edit_and_update
    ukc = client(metro: :fra) { group }
    ukc.services.get(name: "web").edit.set(hard_limit: 20).apply
    ukc.services.edit(name: "web") { |e| e.remove(domains: nil) }

    assert_equal %w[/v1/services /v1/services], @cloud.paths
    assert_equal [{ "name" => "web", "prop" => "hard_limit", "op" => "set", "value" => 20 }],
                 @cloud.calls[0].body
    assert_equal [{ "name" => "web", "prop" => "domains", "op" => "del" }], @cloud.calls[1].body
  end

  def test_delete_goes_to_the_qualified_metro
    ukc = client { group }
    ukc.services.get(name: "web", metro: :was).delete

    assert_equal ["https://api.was.unikraft.cloud/v1/services"], @cloud.calls.map(&:url)
    assert_equal %w[DELETE], @cloud.verbs
    assert_equal [{ "name" => "web" }], @cloud.calls.first.body
  end

  def test_reads_and_creates
    ukc = client(metro: :fra) { group }

    assert_equal 10, ukc.services.get(name: "web").hard_limit
    assert_equal "fra", ukc.services.create(name: "web", services: []).metro
    assert_equal "POST", @cloud.verbs.last
  end

  def test_list_refuses_tags_it_cannot_filter_by
    ukc = client { flunk "no request expected" }

    assert_raises(ArgumentError) { ukc.services.list(tags: ["prod"]) }
  end
end
