# frozen_string_literal: true

require_relative "../test_helper"

class PatchTest < Minitest::Test
  Patch = Unikraft::Cloud::Core::Patch

  def test_a_value_sets_and_nil_removes
    assert_equal [{ prop: "memory_mb", op: "set", value: 512 }, { prop: "autokill", op: "del" }],
                 Patch.changes({ memory_mb: 512, autokill: nil })
  end

  def test_raw_triples_pass_through
    raw = [{ "prop" => "memory_mb", "op" => "set", "value" => 1 }]

    assert_equal [{ prop: "memory_mb", op: "set", value: 1 }], Patch.changes(raw)
    assert_raises(ArgumentError) { Patch.changes({}) }
  end

  def test_editor_stages_in_order
    sent = nil
    result = Patch::Editor.new("instance") { |items| sent = items }
                          .set(memory_mb: 512)
                          .add(env: { LOG_LEVEL: "debug" }, tags: ["prod"])
                          .remove(env: ["OLD"], schedules: nil)
                          .apply

    assert_same sent, result
    assert_equal [
      { prop: "memory_mb", op: "set", value: 512 },
      { prop: "env", op: "add", value: { LOG_LEVEL: "debug" } },
      { prop: "tags", op: "add", value: ["prod"] },
      { prop: "env", op: "del", value: ["OLD"] },
      { prop: "schedules", op: "del" }
    ], sent
  end

  def test_editor_inspect_leaves_out_values
    editor = Patch::Editor.new("instance") { flunk }
                          .set(image: { credentials: "SECRET" }, token: "T")

    assert_equal "#<Unikraft::Cloud::Core::Patch::Editor instance set image, set token>",
                 editor.inspect
  end

  def test_an_empty_edit_refuses_to_apply
    err = assert_raises(ArgumentError) { Patch::Editor.new("instance") { flunk }.apply }

    assert_match(/no changes to apply/, err.message)
  end
end
