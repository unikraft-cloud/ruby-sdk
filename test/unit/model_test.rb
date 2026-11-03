# frozen_string_literal: true

require_relative "../test_helper"

module ModelTestModels
  class Volume < Unikraft::Cloud::Model
    attribute :name
  end

  class Instance < Unikraft::Cloud::Model
    attribute :name
    attribute :volumes, "Volume", array: true
    attribute :env
    attribute :by_name, "Volume", map: true
    attribute :root, "Volume"
    attribute :metro
  end
end

class ModelTest < Minitest::Test
  Instance = ModelTestModels::Instance
  Volume = ModelTestModels::Volume

  def wire
    { "name" => "web", volumes: [{ name: "v1" }], env: { "A" => "1" },
      by_name: { v2: { name: "v2" } }, root: { name: "r" }, extra: { deep: 1 } }
  end

  def test_readers_and_nested_models
    inst = Instance.new(wire)

    assert_equal "web", inst.name
    assert_equal [Volume.new(name: "v1")], inst.volumes
    assert_equal({ "A" => "1" }, inst.env)
    assert_equal "v2", inst.by_name[:v2].name
    assert_equal "r", inst.root.name
  end

  def test_missing_fields_are_nil_and_unknown_keys_kept
    inst = Instance.new(extra: 1)

    assert_nil inst.name
    assert_nil inst.volumes
    assert_equal 1, inst[:extra]
    assert_equal 1, inst["extra"]
  end

  def test_to_h_round_trips
    inst = Instance.new(wire)

    assert_equal "v1", inst.to_h[:volumes].first[:name]
    assert_equal inst, Instance.new(inst.to_h)
    assert_equal JSON.parse(JSON.generate(inst.to_h)), JSON.parse(inst.to_json)
  end

  def test_tolerates_unexpected_shapes
    inst = Instance.new(volumes: "oops", root: 3)

    assert_equal "oops", inst.volumes
    assert_equal 3, inst.root
  end

  def test_equality_and_hash
    a = Instance.new(name: "x")
    b = Instance.new("name" => "x")

    assert_equal a, b
    assert_equal a.hash, b.hash
    refute_equal a, Volume.new(name: "x")
  end

  def test_with_metro_tags_a_copy
    inst = Instance.new(name: "x")
    tagged = inst.with_metro("fra")

    assert_equal "fra", tagged.metro
    assert_nil inst.metro
    refute_includes tagged.to_h, :metro
    refute_equal inst, tagged
  end

  def test_metro_falls_back_to_the_field
    assert_equal "sin", Instance.new(metro: "sin").metro
  end

  def test_from
    inst = Instance.new(name: "x")

    assert_same inst, Instance.from(inst)
    assert_nil Instance.from(nil)
    assert_equal inst, Instance.from(name: "x")
  end

  def test_json_generate_accepts_models
    assert_equal '{"name":"x"}', JSON.generate(Volume.new(name: "x"))
  end
end
