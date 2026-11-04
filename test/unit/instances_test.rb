# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fake_cloud"

class InstancesTest < Minitest::Test
  include FakeCloud::Helpers

  UUID = "550e8400-e29b-41d4-a716-446655440000"

  def instance(name = "web", **fields) = ok(instances: [{ uuid: "u1", name:, **fields }])

  # The web instance, in `metro` only.
  def web_in(metro, call) = ok(instances: call.metro == metro ? [{ uuid: "u1", name: "web" }] : [])

  # --- one metro -----------------------------------------------------------

  def test_get_is_lazy_and_reads_once
    ukc = client(metro: :dal) { instance(state: "running") }
    web = ukc.instances.get(name: "web")

    assert_empty @cloud.calls
    assert_equal "running", web.state
    assert_predicate web, :running?
    assert_equal "dal", web.model.metro
    assert_equal 1, @cloud.calls.size
    call = @cloud.calls.first

    assert_equal "https://api.dal.unikraft.cloud", call.base_url
    assert_equal "/v1/instances", call.path
    # Only the identifier the caller gave is sent.
    assert_equal({ "name" => "web", "details" => "true" }, call.params)
  end

  def test_uuid_refs_query_by_uuid_alone
    ukc = client(metro: :fra) { ok(instances: [{ uuid: UUID }]) }
    ukc.instances.get(uuid: UUID).model

    assert_equal({ "uuid" => UUID, "details" => "true" }, @cloud.calls.first.params)
  end

  def test_refs_need_exactly_one_identifier
    ukc = client(metro: :fra) { flunk }

    assert_raises(ArgumentError) { ukc.instances.get(name: "a", uuid: "b") }
    assert_raises(ArgumentError) { ukc.instances.get }
    assert_raises(ArgumentError) { ukc.instances.get(nme: "web") }
    assert_raises(ArgumentError) { ukc.instances.delete(name: "a", uuid: "b") }
    assert_raises(ArgumentError) { ukc.instances.stop({ name: "web" }, timout: 5) }
    assert_raises(ArgumentError) { ukc.instances.get(name: "web", metro: :fra).stop(timout: 5) }
  end

  def test_http_errors_raise
    ukc = client(metro: :fra) { FakeCloud.failure(404) }
    err = assert_raises(Unikraft::Cloud::Error) { ukc.instances.get(name: "missing").state }

    assert_equal 404, err.status
  end

  def test_a_per_entry_failure_raises
    ukc = client(metro: :fra) do
      { status: "error", message: "Failed to perform all operations",
        data: { instances: [{ status: "error", error: 8,
                              message: "No instance with uuid 'u1'" }] } }
    end
    err = assert_raises(Unikraft::Cloud::Error) { ukc.instances.get(uuid: "u1").model }

    assert_equal 404, err.status
    assert_equal "No instance with uuid 'u1'", err.message
  end

  def test_list_paginates_lazily
    first = Array.new(100) { |n| { uuid: "u#{n}", name: "i#{n}" } }
    ukc = client(metro: :fra) do |call|
      ok(instances: call.params["from"] ? [{ uuid: "u100", name: "i100" }] : first)
    end
    enum = ukc.instances.list

    assert_kind_of Enumerator, enum
    assert_empty @cloud.calls
    assert_equal 101, enum.count
    assert_equal "u99", @cloud.calls[1].params["from"]
    assert_equal "100", @cloud.calls[0].params["count"]
  end

  def test_list_takes_a_block_and_resources_are_enumerable
    ukc = client(metro: :fra) { ok(instances: [{ name: "a", state: "running" }, { name: "b" }]) }
    names = []
    ukc.instances.list(tags: %w[prod]) { |i| names << i.name }

    assert_equal %w[a b], names
    assert_equal "prod", @cloud.calls.last.params["tags"]
    assert_equal ["a"], ukc.instances.select { |i| i.state == "running" }.map(&:name)
    assert_equal "true", @cloud.calls.last.params["details"]
    assert_equal "a", ukc.instances.first.name
    assert_same(ukc.instances, ukc.instances.list { nil })
  end

  def test_a_bug_in_one_metro_propagates_rather_than_failing_it
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal) if call.path == "/v1/metros"
      raise NoMethodError, "bug" if call.metro == "dal"

      ok(instances: [])
    end

    assert_raises(ArgumentError) { ukc.instances.list(colour: "red") }
    assert_raises(NoMethodError) { ukc.instances.to_a }
  end

  def test_list_raises_on_an_error_envelope
    ukc = client(metro: :fra) { { status: "error", message: "nope", errors: [{ status: 500 }] } }

    assert_raises(Unikraft::Cloud::Error) { ukc.instances.to_a }
  end

  def test_create_sends_the_body_as_given
    ukc = client(metro: :fra) { instance }
    ukc.instances.create(image: "nginx:latest", memory_mb: 256)
    ukc.instances.create({ image: { url: "nginx:latest", credentials: "tok" } })
    ukc.instances.create({ image: "a", memory_mb: 128 }, memory_mb: 256)

    assert_equal({ "image" => "nginx:latest", "memory_mb" => 256 }, @cloud.calls[0].body)
    assert_equal({ "image" => { "url" => "nginx:latest", "credentials" => "tok" } },
                 @cloud.calls[1].body)
    assert_equal({ "image" => "a", "memory_mb" => 256 }, @cloud.calls[2].body)
    assert_equal %w[POST POST POST], @cloud.verbs
  end

  def test_create_takes_metro_as_routing
    ukc = client(metros: %i[fra dal]) { instance }

    assert_equal "dal", ukc.instances.create(metro: :dal, image: "x").metro
    assert_equal "api.dal.unikraft.cloud", @cloud.calls.last.host
    assert_equal({ "image" => "x" }, @cloud.calls.last.body)
    assert_raises(ArgumentError) { ukc.instances.create(image: "x", metro: :dal, metros: :fra) }
  end

  def test_logs_and_wait_send_query_params_only
    ukc = client(metro: :fra) { ok(instances: [{ output: "aGk=", state: "running" }]) }
    logs = ukc.instances.logs(name: "web", offset: -4096, limit: 4096)

    assert_equal "aGk=", logs.output
    assert_equal "fra", logs.metro
    assert_equal({ "name" => "web", "offset" => "-4096", "limit" => "4096" },
                 @cloud.calls[0].params)
    assert_nil @cloud.calls[0].body
    ukc.instances.wait(name: "web", state: :running, within: 30)

    assert_equal "/v1/instances/wait", @cloud.calls[1].path
    assert_equal({ "name" => "web", "state" => "running", "timeout_s" => "30" },
                 @cloud.calls[1].params)
    # The read must outlive the server-side wait.
    assert_equal 40, @cloud.calls[1].options[:timeout]
  end

  def test_wait_keeps_timeout_as_the_http_option
    ukc = client(metro: :fra) { instance(state: "running") }
    ukc.instances.get(name: "web").wait(within: 30, timeout: 90)
    ukc.instances.get(name: "web").wait(timeout: 5)

    assert_equal({ "name" => "web", "timeout_s" => "30" }, @cloud.calls[0].params)
    assert_equal 90, @cloud.calls[0].options[:timeout]
    assert_equal({ "name" => "web" }, @cloud.calls[1].params)
    assert_equal 5, @cloud.calls[1].options[:timeout]
  end

  def test_history_and_metrics
    ukc = client(metro: :fra) do
      ok(instances: [{ name: "web", state: "running", history: [{ uuid: "c1" }, { uuid: "c2" }] }])
    end

    assert_equal %w[c1 c2], ukc.instances.history(name: "web").map(&:uuid)
    assert_equal "/v1/instances/history", @cloud.calls.last.path
    assert_equal "running", ukc.instances.get(name: "web").metrics[:state]
    assert_equal "/v1/instances/metrics", @cloud.calls.last.path
  end

  def test_bulk_one_metro_sends_one_call
    ukc = client(metro: :fra) { ok(instances: [{ uuid: "u1" }, { uuid: "u2" }]) }
    results = ukc.instances.delete([{ name: "web" }, { uuid: UUID }])

    assert_equal 1, @cloud.calls.size
    assert_equal "DELETE", @cloud.calls.first.verb
    assert_equal [{ "name" => "web" }, { "uuid" => UUID }], @cloud.calls.first.body
    assert_equal %w[fra fra], results.map(&:metro)
    ukc.instances.stop(name: "web")

    assert_equal ["/v1/instances/stop", [{ "name" => "web" }]],
                 [@cloud.paths.last, @cloud.calls.last.body]
  end

  # --- the two layers ----------------------------------------------------

  def test_a_resource_api_hides_the_token
    api = Unikraft::Cloud.new(token: "secret", metro: :fra).instances.api

    refute_includes api.inspect, "secret"
  end

  def test_per_resource_escape_hatch
    ukc = client(metro: :fra) { ok(instances: [{ uuid: "u1" }]) }

    assert_equal "u1", ukc.instances.api.get_instances(count: 1).data.instances.first.uuid
    ukc.metro(:dal).instances.api.get_instances

    assert_equal "https://api.dal.unikraft.cloud", @cloud.calls.last.base_url
  end

  # --- metro scope -------------------------------------------------------

  def test_fan_out_merges_and_tags
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal, :sin) if call.path == "/v1/metros"

      ok(instances: [{ uuid: "u-#{call.metro}", name: "web-#{call.metro}" }])
    end

    assert_equal %w[dal:web-dal fra:web-fra sin:web-sin],
                 ukc.instances.list(details: true).map { |i| "#{i.metro}:#{i.name}" }.sort
    assert_equal 1, @cloud.paths.count("/v1/metros")
    assert_equal 4, @cloud.calls.size
    ukc.instances.to_a

    assert_equal 1, @cloud.paths.count("/v1/metros")
  end

  def test_named_metros_skip_discovery
    ukc = client { ok(instances: []) }
    ukc.instances.list(metros: %i[fra dal]).to_a

    assert_equal %w[api.dal.unikraft.cloud api.fra.unikraft.cloud], @cloud.calls.map(&:host).sort
    ukc.metros(:sin).instances.to_a

    assert_equal "api.sin.unikraft.cloud", @cloud.calls.last.host
  end

  def test_a_repeated_metro_is_searched_once
    ukc = everywhere(%i[fra dal])

    assert_equal "u-fra", ukc.metros(:fra, "fra").instances.get(name: "web").uuid
    assert_equal 1, @cloud.calls.size
  end

  def test_shorthand_locates_with_the_call_options
    ukc = client do |call|
      ok(instances: call.metro == "fra" ? [{ uuid: "u", name: "web" }] : [])
    end
    ukc.instances.update(name: "web", metros: %i[fra dal], timeout: 5, headers: { "X-A" => "1" },
                         memory_mb: 512)

    assert_equal 3, @cloud.calls.size # two lookups, one update
    assert_equal([5] * 3, @cloud.calls.map { |c| c.options[:timeout] })
    assert_equal([{ "X-A" => "1" }] * 3, @cloud.calls.map { |c| c.options[:headers] })
  end

  def test_a_handle_operation_locates_with_its_own_options
    ukc = client do |call|
      ok(instances: call.metro == "fra" ? [{ uuid: "u", name: "web" }] : [])
    end
    ukc.instances.get(name: "web", metros: %i[fra dal], timeout: 1).suspend(timeout: 5)

    assert_equal([5] * 3, @cloud.calls.map { |c| c.options[:timeout] })
  end

  def test_a_handle_operation_keeps_the_options_of_get
    ukc = client(metro: :fra) { ok(instances: [{ uuid: "u", name: "web" }]) }
    web = ukc.instances.get(name: "web", headers: { "X-A" => "1" })
    web.suspend
    web.logs(timeout: 3)

    assert_equal([{ "X-A" => "1" }] * 2, @cloud.calls.map { |c| c.options[:headers] })
    assert_equal 3, @cloud.calls.last.options[:timeout]
  end

  def test_a_returned_handle_reads_with_the_options_it_ran_with
    ukc = client(metro: :fra) { ok(instances: [{ uuid: "u", name: "web" }]) }
    ukc.instances.get(name: "web").suspend(headers: { "X-B" => "2" }).state

    assert_equal([{ "X-B" => "2" }] * 2, @cloud.calls.map { |c| c.options[:headers] })
  end

  def test_a_set_operation_locates_with_its_own_options
    ukc = everywhere(%i[fra dal])
    ukc.instances.where(name: "web").suspend(timeout: 5)

    timeouts = @cloud.calls.reject { |c| c.path == "/v1/metros" }.map { |c| c.options[:timeout] }

    assert_equal [5] * 4, timeouts # two lookups, two suspends
  end

  def test_qualified_refs_skip_discovery_in_bulk
    ukc = everywhere(%i[fra dal])
    ukc.instances.delete(name: "web", metro: :fra)

    refute_includes @cloud.paths, "/v1/metros"
    assert_equal ["https://api.fra.unikraft.cloud/v1/instances"], @cloud.calls.map(&:url)
  end

  def test_per_call_base_url_is_normalized
    ukc = client { ok(instances: [{ uuid: "u1", name: "web" }]) }
    found = ukc.instances.list(base_url: "https://api.staging.internal/v1/").to_a

    assert_equal ["https://api.staging.internal"], @cloud.calls.map(&:base_url)
    assert_equal "https://api.staging.internal", found.first.metro
  end

  def test_a_url_metro_never_discovers
    ukc = client(metro: "https://api.staging.internal/v1") { ok(instances: [{ uuid: "u1" }]) }
    ukc.instances.to_a

    assert_equal ["https://api.staging.internal/v1/instances"], @cloud.calls.map(&:url)
  end

  def test_partial_failure_drains_healthy_metros_first
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal, :sin) if call.path == "/v1/metros"
      next FakeCloud.failure(503) if call.metro == "sin"

      ok(instances: [{ uuid: "u-#{call.metro}" }])
    end
    seen = []
    err = assert_raises(Unikraft::Cloud::MetroFanoutError) do
      ukc.instances.each { |i| seen << i.metro }
    end

    assert_equal %w[dal fra], seen.sort
    assert_includes err.message, "1 of 3 metros failed: sin (503)"
    assert_equal 503, err.status
  end

  def test_breaking_early_stops_the_other_metros
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal) if call.path == "/v1/metros"

      ok(instances: [{ uuid: "u-#{call.metro}" }])
    end
    ukc.instances.list.first

    assert_operator @cloud.calls.size, :<=, 3
  end

  def test_discovery_failure_explains_itself
    ukc = client { FakeCloud.failure(500) }
    err = assert_raises(Unikraft::Cloud::Error) { ukc.instances.to_a }

    assert_match(/Could not discover/, err.message)
  end

  def test_locates_then_acts_only_where_it_lives
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal, :sin) if call.path == "/v1/metros"
      next instance(state: "standby") if call.path.end_with?("suspend")

      web_in("dal", call)
    end
    suspended = ukc.instances.get(name: "web").suspend

    assert_equal "standby", suspended.state
    assert_equal "dal", suspended.metro
    suspends = @cloud.calls.select { |c| c.path == "/v1/instances/suspend" }

    assert_equal ["api.dal.unikraft.cloud"], suspends.map(&:host)
  end

  def test_missing_everywhere_is_a_404_naming_the_metros
    misses = [
      ok(instances: []),
      { status: "error", message: "Failed to perform all operations",
        data: { instances: [{ status: "error", error: 8,
                              message: "No instance with name 'nope'" }] } }
    ]
    misses.each do |miss|
      ukc = client { |call| call.path == "/v1/metros" ? FakeCloud.metros(:fra, :dal) : miss }
      err = assert_raises(Unikraft::Cloud::Error) { ukc.instances.get(name: "nope").model }

      assert_equal 404, err.status
      assert_equal 'instance name "nope" not found in fra, dal', err.message
    end
  end

  def test_bulk_acts_on_every_metro_a_name_matches
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal, :sin) if call.path == "/v1/metros"
      next ok(instances: []) if call.verb == "GET" && call.metro == "sin"
      next instance if call.verb == "GET"

      ok(instances: [{ uuid: "u-#{call.metro}" }])
    end
    deleted = ukc.instances.delete(name: "web")

    deletes = @cloud.calls.select { |c| c.verb == "DELETE" }

    assert_equal %w[api.dal.unikraft.cloud api.fra.unikraft.cloud], deletes.map(&:host).sort
    assert(deletes.all? { |c| c.body == [{ "name" => "web" }] })
    assert_equal %w[dal fra], deleted.map(&:metro).sort
  end

  def test_bulk_groups_refs_by_metro
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal) if call.path == "/v1/metros"

      if call.verb == "GET"
        name = call.params["name"]
        here = (call.metro == "fra" && name == "a") || (call.metro == "dal" && name == "b")
        next ok(instances: here ? [{ uuid: "u-#{name}", name: }] : [])
      end
      ok(instances: [{ uuid: "u-#{call.metro}" }])
    end
    ukc.instances.delete([{ name: "a" }, { name: "b" }])
    deletes = @cloud.calls.select { |c| c.verb == "DELETE" }.to_h { |c| [c.metro, c.body] }

    assert_equal({ "fra" => [{ "name" => "a" }], "dal" => [{ "name" => "b" }] }, deletes)
  end

  def test_bulk_locates_refs_concurrently
    mutex = Mutex.new
    in_flight = peak = 0
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal) if call.path == "/v1/metros"
      next ok(instances: [{ uuid: "u" }]) unless call.verb == "GET"

      mutex.synchronize { peak = [peak, in_flight += 1].max }
      sleep 0.05
      mutex.synchronize { in_flight -= 1 }
      ok(instances: call.metro == "fra" ? [{ uuid: "u", name: call.params["name"] }] : [])
    end
    ukc.instances.stop([{ name: "a" }, { name: "b" }])

    # Two refs across two metros: one at a time would peak at two.
    assert_operator peak, :>, 2
  end

  def test_bulk_partial_failure_keeps_results
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal) if call.path == "/v1/metros"
      next FakeCloud.failure(503) if call.verb == "PUT" && call.metro == "dal"

      ok(instances: [{ uuid: "u-#{call.metro}", name: "web" }])
    end
    err = assert_raises(Unikraft::Cloud::MetroFanoutError) { ukc.instances.stop(name: "web") }

    assert_equal ["fra"], err.results.map(&:metro)
    assert_equal(["dal"], err.failures.map { |f| f[:metro] })
  end

  def test_create_needs_one_metro
    ukc = client { instance }

    assert_equal "fra", ukc.instances.create(image: "nginx:latest").metro
    assert_equal ["https://api.fra.unikraft.cloud/v1/instances"], @cloud.calls.map(&:url)
    assert_equal "sfo", ukc.instances.create(image: "nginx:latest", metros: :sfo).metro
    sin = client(metro: :sin, metros: :all) { instance }

    assert_equal "sin", sin.instances.create(image: "x").metro
    assert_equal "fra", ukc.metros(:dal, :fra).instances.create(image: "x").metro
    # Only the default metro is a fallback; elsewhere is refused.
    err = assert_raises(Unikraft::Cloud::Error) do
      ukc.metros(:sin, :dal).instances.create(image: "nginx:latest")
    end

    assert_equal :config, err.kind
    assert_match(/targets a single metro/, err.message)
  end

  # --- handles -----------------------------------------------------------

  def test_one_request_when_the_metro_is_known
    ukc = client(metro: :fra) { instance(state: "standby") }
    suspended = ukc.instances.get(name: "web").suspend

    assert_equal 1, @cloud.calls.size
    assert_equal %w[PUT], @cloud.verbs
    assert_equal ["/v1/instances/suspend"], @cloud.paths
    assert_equal [{ "name" => "web" }], @cloud.calls.first.body
    assert_equal "fra", suspended.metro
    assert_kind_of Unikraft::Cloud::Resources::InstanceHandle, suspended
  end

  def test_chained_steps_run_once_and_in_order
    ukc = client(metro: :fra) do |call|
      next ok(instances: [{ uuid: "u1", state: "running" }]) if call.path == "/v1/instances/wait"
      next ok(instances: [{ output: "aGk=" }]) if call.path == "/v1/instances/log"

      instance
    end
    logs = ukc.instances.create(image: "nginx:latest").wait(state: :running).logs(offset: -1024)

    assert_equal "aGk=", logs.output
    assert_equal %w[/v1/instances /v1/instances/wait /v1/instances/log], @cloud.paths
    # The created instance is addressed by its uuid from then on.
    assert_equal({ "uuid" => "u1", "state" => "running" }, @cloud.calls[1].params)
  end

  def test_history_raises_a_failed_entry
    ukc = client(metro: :fra) do
      { status: "partial_success", data: { instances: [{ status: "error", error: 8 }] } }
    end
    err = assert_raises(Unikraft::Cloud::Error) { ukc.instances.history(name: "web") }

    assert_equal 404, err.status
  end

  def test_reload_keeps_the_read_options_of_get
    ukc = client(metro: :fra) { instance }
    web = ukc.instances.get(name: "web", timeout: 5)
    web.reload
    web.reload(timeout: 7)

    assert_equal([5, 7], @cloud.calls.map { |c| c.options[:timeout] })
  end

  def test_a_handle_memoizes_and_reloads
    ukc = client(metro: :fra) { instance }
    web = ukc.instances.get(name: "web")
    web.name
    web.to_h

    assert_equal 1, @cloud.calls.size
    assert_same web, web.reload
    assert_equal 2, @cloud.calls.size
  end

  def test_location_and_inspect
    ukc = client(metro: :dal) { instance }
    web = ukc.instances.get(name: "web")

    assert_match(/name "web" \(not loaded\)/, web.inspect)
    assert_equal "dal", web.metro
    assert_equal "https://api.dal.unikraft.cloud", web.location.base_url
    assert_equal({ name: "web" }, web.resolve.ref.wire)
    assert_empty @cloud.calls
    web.model

    assert_match(/state=|name="web"/, web.inspect)
  end

  def test_extra_fields_of_a_mutation_result_are_readable
    ukc = client(metro: :fra) { instance(state: "standby", previous_state: "running") }
    suspended = ukc.instances.get(name: "web").suspend

    assert_equal "running", suspended[:previous_state]
    assert_respond_to suspended, :state
    assert_pattern { suspended => { state: "standby", metro: "fra" } }
  end

  def test_an_attribute_missing_from_a_mutation_reply_is_read_once
    ukc = client(metro: :fra) do |call|
      next ok(instances: [{ uuid: "u1", name: "web" }]) if call.verb == "PATCH"

      instance(state: "running", memory_mb: 512)
    end
    updated = ukc.instances.update(name: "web", memory_mb: 512)

    assert_predicate updated, :running?
    assert_equal 512, updated.memory_mb
    assert_nil updated.vcpus
    assert_equal %w[PATCH GET], @cloud.verbs
  end

  # --- a name in several metros -----------------------------------------

  def test_get_reports_ambiguity_with_the_matches
    ukc = everywhere(%i[fra dal sin])
    err = assert_raises(Unikraft::Cloud::AmbiguousRefError) { ukc.instances.get(name: "web").suspend }

    assert_equal %w[dal fra sin], err.metros.sort
    assert_equal %w[u-dal u-fra u-sin], err.matches.map(&:uuid).sort
    assert_includes err.message, "metro: :"
    assert_equal 0, @cloud.paths.count("/v1/instances/suspend")
  end

  def test_get_refuses_a_match_while_another_metro_is_unreachable
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal) if call.path == "/v1/metros"
      next FakeCloud.failure(503) if call.metro == "dal"

      ok(instances: [{ uuid: "u-#{call.metro}", name: "web" }])
    end
    err = assert_raises(Unikraft::Cloud::MetroFanoutError) { ukc.instances.get(name: "web").suspend }

    assert_equal ["fra"], err.results.map(&:metro)
    assert_equal(["dal"], err.failures.map { |f| f[:metro] })
    assert_equal 0, @cloud.paths.count("/v1/instances/suspend")
  end

  def test_a_failed_lookup_entry_counts_as_absent
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal) if call.path == "/v1/metros"
      next ok(instances: [{ uuid: "u-fra", name: "web" }]) if call.metro == "fra"

      { status: "partial_success", data: { instances: [{ status: "error", error: 8 }] } }
    end

    assert_equal "fra", ukc.instances.get(name: "web").metro
  end

  def test_a_uuid_in_several_metros_is_ambiguous_too
    ukc = everywhere(%i[fra dal])
    err = assert_raises(Unikraft::Cloud::AmbiguousRefError) { ukc.instances.get(uuid: "u").metro }

    assert_equal %w[dal fra], err.metros.sort
    assert_includes err.message, 'get(uuid: "u", metro: :'
  end

  def test_a_qualified_ref_needs_no_lookup
    ukc = everywhere(%i[fra dal sin])
    suspended = ukc.instances.get(name: "web", metro: :dal).suspend

    assert_equal "dal", suspended.metro
    assert_equal ["https://api.dal.unikraft.cloud/v1/instances/suspend"], @cloud.calls.map(&:url)
    assert_equal [{ "name" => "web" }], @cloud.calls.first.body
  end

  def test_where_acts_on_every_match
    ukc = everywhere(%i[fra dal sin])
    results = ukc.instances.where(name: "web").suspend

    assert_equal %w[dal fra sin], results.map(&:metro).sort
    assert_equal 3, @cloud.paths.count("/v1/instances/suspend")
  end

  def test_where_is_enumerable_and_located_once
    ukc = everywhere(%i[fra dal])
    web = ukc.instances.where(name: "web")

    assert_equal 2, web.size
    assert_equal %w[dal fra], web.metros.sort
    assert_equal %w[u-dal u-fra], web.map(&:uuid).sort
    assert_equal 1, @cloud.paths.count("/v1/metros")
    assert_equal 2, @cloud.paths.count("/v1/instances")
  end

  def test_where_applies_a_staged_edit_everywhere
    ukc = everywhere(%i[fra dal])
    ukc.instances.where(name: "web").edit.set(memory_mb: 512).apply
    patches = @cloud.calls.select { |c| c.verb == "PATCH" }

    assert_equal 2, patches.size
    assert_equal [{ "name" => "web", "prop" => "memory_mb", "op" => "set", "value" => 512 }],
                 patches.first.body
  end

  def test_where_keeps_the_successes_on_partial_failure
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal) if call.path == "/v1/metros"
      next FakeCloud.failure(503) if call.path.end_with?("suspend") && call.metro == "dal"

      ok(instances: [{ uuid: "u-#{call.metro}", name: "web" }])
    end
    err = assert_raises(Unikraft::Cloud::MetroFanoutError) { ukc.instances.where(name: "web").suspend }

    assert_equal(["dal"], err.failures.map { |f| f[:metro] })
    assert_equal ["fra"], err.results.map(&:metro)
  end

  def test_where_with_one_metro_needs_no_lookup
    ukc = everywhere(%i[fra dal], metro: :fra)
    ukc.instances.where(name: "web").suspend

    assert_equal ["https://api.fra.unikraft.cloud/v1/instances/suspend"], @cloud.calls.map(&:url)
  end

  # --- updating ------------------------------------------------------------

  def body = @cloud.calls.first.body

  def test_update_infers_set_and_nil_removes
    ukc = client(metro: :fra) { instance }
    ukc.instances.get(name: "web").update(memory_mb: 512, tags: nil)

    assert_equal "PATCH", @cloud.calls.first.verb
    assert_equal [{ "name" => "web", "prop" => "memory_mb", "op" => "set", "value" => 512 },
                  { "name" => "web", "prop" => "tags", "op" => "del" }], body
  end

  def test_update_accepts_raw_triples_and_the_shorthand
    ukc = client(metro: :fra) { instance }
    ukc.instances.update({ name: "web" }, [{ prop: "memory_mb", op: "set", value: 512 }])
    ukc.instances.update(name: "web", image: { url: "nginx:1.27" })

    assert_equal [{ "name" => "web", "prop" => "memory_mb", "op" => "set", "value" => 512 }], body
    assert_equal [{ "name" => "web", "prop" => "image", "op" => "set",
                    "value" => { "url" => "nginx:1.27" } }], @cloud.calls.last.body
  end

  def test_update_keywords_never_patch_call_options
    ukc = client(metro: :fra) { instance }
    ukc.instances.update(name: "web", memory_mb: 512, timeout: 10, headers: { "X-A" => "1" })
    ukc.instances.get(name: "web").update(vcpus: 2, timeout: 5)

    assert_equal [{ "name" => "web", "prop" => "memory_mb", "op" => "set", "value" => 512 }],
                 @cloud.calls[0].body
    assert_equal({ timeout: 10, headers: { "X-A" => "1" } },
                 @cloud.calls[0].options.except(:base_url))
    assert_equal 5, @cloud.calls[1].options[:timeout]
    assert_equal 1, @cloud.calls[1].body.size
  end

  def test_edit_chains_or_takes_a_block
    ukc = client(metro: :fra) { instance }
    updated = ukc.instances.get(name: "web").edit
                 .set(memory_mb: 512)
                 .add(env: { LOG_LEVEL: "debug" }, tags: ["prod"])
                 .remove(env: ["OLD_FLAG"], schedules: nil)
                 .apply
    ukc.instances.edit(name: "web") { |e| e.set(vcpus: 2) }

    assert_equal "fra", updated.metro
    assert_equal [
      { "name" => "web", "prop" => "memory_mb", "op" => "set", "value" => 512 },
      { "name" => "web", "prop" => "env", "op" => "add", "value" => { "LOG_LEVEL" => "debug" } },
      { "name" => "web", "prop" => "tags", "op" => "add", "value" => ["prod"] },
      { "name" => "web", "prop" => "env", "op" => "del", "value" => ["OLD_FLAG"] },
      { "name" => "web", "prop" => "schedules", "op" => "del" }
    ], body
    assert_equal [{ "name" => "web", "prop" => "vcpus", "op" => "set", "value" => 2 }],
                 @cloud.calls.last.body
    assert_raises(ArgumentError) { ukc.instances.edit(name: "web").apply }
  end

  def test_chaining_continues_after_an_edit
    ukc = client(metro: :fra) { instance(state: "running") }
    ukc.instances.edit(name: "web").set(memory_mb: 512).apply.wait

    assert_equal %w[/v1/instances /v1/instances/wait], @cloud.paths
  end

  def test_an_edit_goes_to_the_metro_holding_the_instance
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal) if call.path == "/v1/metros"
      next web_in("dal", call) if call.verb == "GET"

      instance
    end
    ukc.instances.get(name: "web").edit { |e| e.add(tags: ["prod"]) }

    patches = @cloud.calls.select { |c| c.verb == "PATCH" }

    assert_equal ["api.dal.unikraft.cloud"], patches.map(&:host)
  end

  def test_the_client_is_shared_across_threads
    ukc = client do |call|
      next FakeCloud.metros(:fra, :dal) if call.path == "/v1/metros"

      ok(instances: [{ uuid: "u-#{call.metro}" }])
    end
    counts = Array.new(8) { Thread.new { ukc.instances.count } }.map(&:value)

    assert_equal [2], counts.uniq
    assert_equal 1, @cloud.paths.count("/v1/metros")
  end
end
