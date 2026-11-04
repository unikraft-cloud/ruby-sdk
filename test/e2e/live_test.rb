# frozen_string_literal: true

# The porcelain against a live account. Run with `bundle exec rake test:e2e`;
# it needs UKC_TOKEN. UKC_METRO picks the deployment (a metro code or a URL;
# the internal staging deployment by default) and UKC_E2E_IMAGE the image.

require_relative "../test_helper"
require "English"
require "securerandom"

class LiveTest < Minitest::Test
  # Tracks the prod-staging platform branch, where a platform fix can be
  # checked before the OpenAPI specification catches up with it.
  METRO = "http://api.ukp-staging.apw.unikraft.internal"
  IMAGE = "nginx:latest"

  def env(name)
    value = ENV.fetch(name, nil)
    value unless value.nil? || value.empty?
  end

  def setup
    skip "UKC_TOKEN is missing or empty" unless env("UKC_TOKEN")
    @ukc = Unikraft::Cloud.new(metro: env("UKC_METRO") || METRO)
  end

  def teardown
    @ukc&.close
  end

  def test_lists_every_instance_in_scope
    instances = @ukc.instances.list.first(5)

    assert(instances.all? { |i| i.metro.is_a?(String) })
    refute_empty @ukc.users.quotas
  end

  def test_instance_lifecycle
    name = "ruby-sdk-e2e-#{SecureRandom.hex(4)}"
    scope = @ukc.metro(@ukc.scope.first)
    created = scope.instances.create(name:, image: env("UKC_E2E_IMAGE") || IMAGE,
                                     memory_mb: 256, autostart: true)
    running = created.wait(state: :running, within: 60)

    assert_equal "running", running.state
    assert_kind_of String, running.logs(offset: -4096).output.to_s
    web = scope.instances.get(name:)

    assert_equal created.uuid, web.uuid
    assert_predicate web, :running?
    web.update(memory_mb: 512)

    assert_equal 512, web.reload.memory_mb
  ensure
    # Always try: a create can succeed remotely yet raise here (a lost
    # reply). Absent is fine, and a cleanup failure never masks the test's.
    failure = $ERROR_INFO
    begin
      scope&.instances&.delete(name:)
    rescue Unikraft::Cloud::Error => e
      raise unless e.status == 404 || failure
    end
  end
end
