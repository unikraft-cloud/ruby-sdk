# frozen_string_literal: true

require_relative "../test_helper"

class ReadyTest < Minitest::Test
  Ready = Unikraft::Cloud::Core::Ready
  Error = Unikraft::Cloud::Error

  FAST = { initial_delay: 0.001, max_delay: 0.002 }.freeze

  def http(status) = Error.new("HTTP #{status}", kind: :http, status: status)

  def test_returns_once_the_probe_succeeds
    calls = 0
    Ready.wait_until_ready(**FAST) do |left|
      calls += 1

      assert_operator left, :>, 0
      raise http(503) if calls < 3
    end

    assert_equal 3, calls
  end

  def test_retries_network_and_gateway_statuses
    errors = [Error.new("refused", kind: :network), http(404), http(502), http(503), http(504)]
    Ready.wait_until_ready(**FAST) do
      raise errors.shift unless errors.empty?
    end

    assert_empty errors
  end

  def test_rethrows_401_and_403_at_once
    [401, 403, 500].each do |status|
      calls = 0
      err = assert_raises(Error) do
        Ready.wait_until_ready(**FAST) do
          calls += 1
          raise http(status)
        end
      end

      assert_equal status, err.status
      assert_equal 1, calls
    end
  end

  def test_rethrows_foreign_exceptions
    assert_raises(KeyError) { Ready.wait_until_ready(**FAST) { raise KeyError } }
  end

  def test_times_out_with_the_last_error_as_cause
    last = http(502)
    err = assert_raises(Error) do
      Ready.wait_until_ready(**FAST, timeout: 0.02, what: "sandbox x",
                                     diagnose: ->(e) { "state is #{e.status}" }) { raise last }
    end

    assert_equal :timeout, err.kind
    assert_nil err.status
    assert_same last, err.cause
    assert_match(/\Asandbox x was not ready within 0.02 s \(\d+ probes\): state is 502\. /,
                 err.message)
    assert_match(/The last attempt failed with: HTTP 502\z/, err.message)
  end

  def test_a_failing_diagnosis_keeps_the_timeout
    err = assert_raises(Error) do
      Ready.wait_until_ready(**FAST, timeout: 0, diagnose: ->(_) { raise "boom" }) do
        raise http(503)
      end
    end

    assert_equal :timeout, err.kind
    assert_match(/\(1 probe\)\. /, err.message)
  end

  def test_backoff_doubles_up_to_the_cap
    stamps = []
    assert_raises(Error) do
      Ready.wait_until_ready(initial_delay: 0.01, max_delay: 0.04, timeout: 0.2) do
        stamps << Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise http(503)
      end
    end
    gaps = stamps.each_cons(2).map { |a, b| b - a }

    assert_operator gaps.first, :>=, 0.005
    assert(gaps[0...-1].all? { |g| g < 0.06 }, "a gap exceeded the cap: #{gaps}")
  end

  def test_rejects_unusable_durations
    [{ initial_delay: 0 }, { max_delay: -1 }, { timeout: Float::NAN },
     { timeout: "1" }].each do |bad|
      assert_raises(ArgumentError) { Ready.wait_until_ready(**bad) { nil } }
    end
  end
end
