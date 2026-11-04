# frozen_string_literal: true

require_relative "../test_helper"

class PoolTest < Minitest::Test
  Pool = Unikraft::Cloud::Core::Pool

  Conn = Struct.new(:finished) do
    def finish = self.finished = true
  end

  def test_keys_are_separate_and_most_recent_first
    pool = Pool.new
    a = Conn.new
    b = Conn.new
    pool.checkin(:x, a)
    pool.checkin(:x, b)

    assert_nil pool.checkout(:y)
    assert_same b, pool.checkout(:x)
    assert_same a, pool.checkout(:x)
    assert_nil pool.checkout(:x)
  end

  def test_extra_idle_connections_are_closed
    pool = Pool.new(max_idle: 1)
    kept = Conn.new
    extra = Conn.new
    pool.checkin(:x, kept)
    pool.checkin(:x, extra)

    assert extra.finished
    refute kept.finished
  end

  def test_expired_connections_are_closed_on_checkout
    pool = Pool.new(keep_alive: 0)
    old = Conn.new
    pool.checkin(:x, old)

    assert_nil pool.checkout(:x)
    assert old.finished
  end

  def test_a_forked_child_forgets_inherited_connections_without_closing
    pool = Pool.new
    inherited = Conn.new
    pool.checkin(:x, inherited)
    pool.instance_variable_set(:@pid, -1)

    assert_nil pool.checkout(:x)
    pool.close

    refute inherited.finished
  end
end
