# frozen_string_literal: true

# Sandboxes against a live account: real virtual machines. Run with
# `bundle exec rake test:e2e`; it needs UKC_TOKEN. UKC_METRO picks the
# deployment, UKC_SANDBOX_IMAGE the image and UKC_E2E_SANDBOX_ROM the plugin.

require_relative "../test_helper"
require "securerandom"

class SandboxLiveTest < Minitest::Test
  Sandbox = Unikraft::Cloud::Sandbox
  # The deployment live_test.rb uses by default.
  METRO = "http://api.ukp-staging.apw.unikraft.internal"

  def env(name)
    value = ENV.fetch(name, nil)
    value unless value.nil? || value.empty?
  end

  def setup
    skip "UKC_TOKEN is missing or empty" unless env("UKC_TOKEN")
    @ukc = Unikraft::Cloud.new(metro: env("UKC_METRO") || METRO)
    @spec = { rom: env("UKC_E2E_SANDBOX_ROM") }.compact
  end

  def teardown
    @ukc&.close
  end

  def sandboxes = @ukc.metro(@ukc.scope.first).sandboxes

  # One machine for the commands and files, since a boot is expensive and
  # these cannot disturb one another.
  def test_a_live_sandbox
    sandboxes.create(**@spec) do |sb|
      res = sb.run("echo hello")

      assert_equal ["hello\n", "", 0], [res.stdout, res.stderr, res.exitcode]
      # The plugin answers 200 for a command that ran and failed.
      assert_equal 3, sb.run("sh", "-c", "exit 3").exitcode

      path = "/tmp/round-trip-#{SecureRandom.hex(4)}"
      sb.files.write(path, "hello\n")

      assert_equal "hello\n".b, sb.files.read(path)
      # Bytes go up base64 and come back raw: no UTF-8 decoder round-trips these.
      sb.files.write(path, "\x00\x01\xFE\xFF".b)

      assert_equal "\x00\x01\xFE\xFF".b, sb.files.read(path)
      assert_includes sandboxes.map(&:uuid), sb.uuid
    end
  end

  def test_the_create_block_deletes_the_sandbox
    uuid = sandboxes.create(**@spec) do |sb|
      assert_equal "running", sb.instance.state
      sb.uuid
    end
    # The platform answers HTTP 200 with an error envelope; the SDK reads
    # the entry's code as the 404.
    err = assert_raises(Unikraft::Cloud::Error) { Sandbox.connect(uuid:, client: @ukc) }

    assert_equal 404, err.status
  end
end
