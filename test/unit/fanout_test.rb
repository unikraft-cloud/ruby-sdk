# frozen_string_literal: true

require_relative "../test_helper"
require "timeout"

class FanoutTest < Minitest::Test
  Core = Unikraft::Cloud::Core

  def endpoints(*codes) = codes.map { |c| Core::Metro.endpoint(c) }

  def failure(status) = Unikraft::Cloud::Error.new("down", kind: :http, status:)

  def test_merge_interleaves_in_arrival_order
    slow = Queue.new
    out = []
    Core::Fanout.merge(endpoints(:fra, :dal), out) do |endpoint, emit|
      if endpoint.metro == "fra"
        slow.pop # fra answers only after dal has delivered
        emit.call("fra")
      else
        emit.call("dal")
        slow << :go
      end
    end

    assert_equal %w[dal fra], out
  end

  def test_merge_drains_healthy_metros_then_raises
    out = []
    err = assert_raises(Unikraft::Cloud::MetroFanoutError) do
      Core::Fanout.merge(endpoints(:fra, :dal, :sin), out) do |endpoint, emit|
        raise failure(503) if endpoint.metro == "sin"

        emit.call(endpoint.metro)
      end
    end

    assert_equal %w[dal fra], out.sort
    assert_includes err.message, "1 of 3 metros failed: sin (503)"
    assert_equal(["sin"], err.failures.map { |f| f[:metro] })
    assert_equal 503, err.status
  end

  def test_merge_with_one_metro_raises_the_error_itself
    err = assert_raises(Unikraft::Cloud::Error) do
      Core::Fanout.merge(endpoints(:fra), []) { raise failure(500) }
    end

    refute_kind_of Unikraft::Cloud::MetroFanoutError, err
  end

  def test_merge_stops_the_remaining_metros_on_break
    before = Thread.list.size
    enum = Enumerator.new do |y|
      Core::Fanout.merge(endpoints(:fra, :dal), y) do |endpoint, emit|
        emit.call(endpoint.metro) if endpoint.metro == "fra"
        sleep
      end
    end

    assert_equal "fra", enum.first
    deadline = Time.now + 5
    Thread.pass until Thread.list.size == before || Time.now > deadline

    assert_equal before, Thread.list.size
  end

  def test_merge_reraises_what_is_not_an_error
    [ArgumentError, NotImplementedError].each do |klass|
      assert_raises(klass) do
        Timeout.timeout(5) do
          Core::Fanout.merge(endpoints(:fra, :dal), []) do |endpoint, emit|
            raise klass, "bug" if endpoint.metro == "dal"

            emit.call(endpoint.metro)
          end
        end
      end
    end
  end

  def test_merge_buffers_about_one_item_per_metro
    emitted = Queue.new
    enum = Enumerator.new do |y|
      Core::Fanout.merge(endpoints(:fra, :dal), y) do |endpoint, emit|
        100.times do |i|
          emit.call(i)
          emitted << endpoint.metro
        end
      end
    end
    enum.next
    sleep 0.05

    # Each producer parks on the full queue instead of running ahead.
    assert_operator emitted.size, :<=, 4
  ensure
    enum&.rewind
  end

  def test_settled_reraises_what_is_not_an_error
    assert_raises(NoMethodError) do
      Core::Fanout.settled(endpoints(:fra, :dal)) { |e| e.metro == "dal" ? nil.boom : 1 }
    end
  end

  def test_settled_stops_the_rest_when_one_raises
    finished = false
    assert_raises(NoMethodError) do
      Core::Fanout.settled(endpoints(:dal, :fra)) do |e|
        next nil.boom if e.metro == "dal"

        sleep 0.2
        finished = true
      end
    end
    sleep 0.3

    refute finished
  end

  def test_settled_raises_a_later_failure_while_an_earlier_item_blocks
    gate = Queue.new
    assert_raises(NoMethodError) do
      Timeout.timeout(2) do
        Core::Fanout.settled(endpoints(:fra, :dal)) { |e| e.metro == "fra" ? gate.pop : nil.boom }
      end
    end
  end

  def test_all_keeps_the_successes_on_failure
    err = assert_raises(Unikraft::Cloud::MetroFanoutError) do
      Core::Fanout.all(endpoints(:fra, :dal), flat: true) do |endpoint|
        raise failure(503) if endpoint.metro == "dal"

        [1, 2]
      end
    end

    assert_equal [1, 2], err.results
    assert_equal [[1], [2]], Core::Fanout.all(endpoints(:fra, :dal)) { |e| [e.metro == "fra" ? 1 : 2] }
  end

  def test_pagination_follows_the_cursor
    pages = { nil => [{ uuid: "a" }, { uuid: "b" }], "b" => [{ uuid: "c" }] }
    seen = []
    items = []
    Core::Pagination.each(page_size: 2, fetch: lambda { |count, from|
      seen << [count, from]
      pages.fetch(from)
    }) { |item| items << item[:uuid] }

    assert_equal %w[a b c], items
    assert_equal [[2, nil], [2, "b"]], seen
  end

  def test_pagination_stops_without_a_cursor
    calls = 0
    Core::Pagination.each(page_size: 1, fetch: lambda { |_, _|
      calls += 1
      [{}]
    }) { nil }

    assert_equal 1, calls
  end
end
