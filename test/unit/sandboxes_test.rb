# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fake_cloud"
require "stringio"

# The sandboxes porcelain over a FakeCloud whose plugin routes answer like
# the sandbox plugin. A port of the JS SDK's test/sandbox.test.ts, plus the
# Ruby surface.
class SandboxesTest < Minitest::Test
  include FakeCloud::Helpers

  Sandbox = Unikraft::Cloud::Sandbox
  Error = Unikraft::Cloud::Error
  PLUGIN = "https://api.fra.unikraft.cloud/v1/instances/u1/plugins/sandbox"
  FAST = { within: 0.05, initial_delay: 0.001 }.freeze

  def setup
    super
    @saved_image = ENV.delete("UKC_SANDBOX_IMAGE")
  end

  def teardown
    @saved_image ? ENV["UKC_SANDBOX_IMAGE"] = @saved_image : ENV.delete("UKC_SANDBOX_IMAGE")
    super
  end

  INSTANCE = { uuid: "u1", state: "running", plugins: [{ name: "sandbox", rom: "r" }] }.freeze

  # The sandbox plugin's answers, for the routes these tests use.
  def plugin(call)
    case [call.verb, call.path]
    in ["POST", "/commands"] then ok(uuid: "c1")
    in ["GET", "/commands"] then ok(commands: %w[c1 c2])
    in ["POST", "/commands/c1/wait_timeout"] then [408, { status: "error", message: "Timed out" }]
    in ["GET", "/commands/c1"] then ok(uuid: "c1", cmdline: "x", exitcode: @exitcode)
    in ["GET", "/commands/c1/logs"]
      ok(stdout: ["hi\n"].pack("m0"), stderr: "", stdout_available: 3, stderr_available: 0)
    in ["GET", "/commands/c1/logs/raw/stdout"] then "\x00\xFF"
    in ["POST", "/fs/read_raw"] then "\x00\x01\xFE\xFF"
    in ["POST" | "DELETE", _] then ok(nil)
    end
  end

  # A client whose platform holds INSTANCE (or `instance`) and whose plugin
  # answers through #plugin. The block may answer first; nil falls through.
  def cloud(instance: INSTANCE, metros: nil, **opts, &extra)
    client(**opts) do |call|
      hit = extra&.call(call)
      next hit if hit
      next plugin(call) if call.base_url.include?("/plugins/")
      next metros if metros && call.path == "/v1/metros"

      ok(instances: [instance])
    end
  end

  def posts = @cloud.calls.select { |c| c.verb == "POST" }
  def creates = @cloud.calls.select { |c| c.verb == "POST" && c.path == "/v1/instances" }

  # --- creating ------------------------------------------------------------

  def test_create_takes_the_defaults_and_probes_the_plugin
    sb = cloud(metro: :fra).metro(:fra).sandboxes.create
    body = creates.first.body

    assert_equal({ "image" => Sandbox::DEFAULT_IMAGE, "memory_mb" => 2048,
                   "plugins" => [{ "name" => "sandbox", "rom" => Sandbox::DEFAULT_PLUGIN_ROM }],
                   "autokill" => { "time_ms" => Sandbox::DEFAULT_AUTOKILL_MS },
                   "autostart" => true, "timeout_s" => Sandbox::DEFAULT_BOOT_WITHIN }, body)
    assert_equal "u1", sb.uuid
    assert_equal "fra", sb.metro
    assert_equal PLUGIN, sb.base_url
    probe = @cloud.calls.last

    assert_equal ["GET", PLUGIN, "/commands"], [probe.verb, probe.base_url, probe.path]
  end

  def test_the_spec_and_the_environment_beat_the_defaults
    fra = cloud(metro: :fra).metro(:fra)
    fra.sandboxes.create(image: "img", memory_mb: 512)

    assert_equal %w[img 512], creates.last.body.values_at("image", "memory_mb").map(&:to_s)
    ENV["UKC_SANDBOX_IMAGE"] = "from-env"
    fra.sandboxes.create

    assert_equal "from-env", creates.last.body["image"]
    fra.sandboxes.create({ "image" => "img" })

    assert_equal "img", creates.last.body["image"]
    ENV["UKC_SANDBOX_IMAGE"] = ""
    fra.sandboxes.create(image: "")

    assert_equal Sandbox::DEFAULT_IMAGE, creates.last.body["image"]
  end

  def test_a_snapshot_source_gets_no_image_memory_or_plugin
    ENV["UKC_SANDBOX_IMAGE"] = "from-env"
    fra = cloud(metro: :fra).metro(:fra)
    [{ template: { uuid: "t1" } }, { branch_from: { name: "o" } },
     { checkpoint: { name: "cp" } }].each do |source|
      fra.sandboxes.create(**source)
      body = creates.last.body

      assert body["autostart"]
      assert_equal({ "time_ms" => Sandbox::DEFAULT_AUTOKILL_MS }, body["autokill"])
      assert_empty body.keys & %w[image memory_mb plugins]
    end
  end

  def test_the_boot_wait_follows_ready
    fra = cloud(metro: :fra).metro(:fra)
    fra.sandboxes.create(ready: false)

    assert_equal 0, creates.last.body["timeout_s"]
    refute(@cloud.calls.any? { |c| c.base_url.include?("/plugins/") })
    fra.sandboxes.create(ready: false, boot_within: 10)

    assert_equal 10, creates.last.body["timeout_s"]
    # The create request is held open for the boot, unless timeout: says.
    assert_equal 20, creates.last.options[:timeout]
    fra.sandboxes.create(ready: false, boot_within: 10, timeout: 5)

    assert_equal 5, creates.last.options[:timeout]
  end

  def test_the_callers_own_plugin_entry_is_kept
    fra = cloud(metro: :fra).metro(:fra)
    fra.sandboxes.create(image: "img",
                         plugins: [{ name: "sandbox", rom: "mine:1", config: { a: 1 } }])

    assert_equal [{ "name" => "sandbox", "rom" => "mine:1", "config" => { "a" => 1 } }],
                 creates.last.body["plugins"]
    fra.sandboxes.create(image: "img", plugins: [{ name: "other", rom: "o:1" }])

    assert_equal [{ "name" => "sandbox", "rom" => Sandbox::DEFAULT_PLUGIN_ROM },
                  { "name" => "other", "rom" => "o:1" }], creates.last.body["plugins"]
    fra.sandboxes.create(template: { uuid: "t1" }, plugins: [{ name: "other", rom: "o:1" }])

    assert_equal [{ "name" => "other", "rom" => "o:1" }], creates.last.body["plugins"]
    custom = fra.sandboxes.create(template: { uuid: "t1" }, plugin_name: "custom")

    assert_equal "custom", custom.plugin_name
    assert_nil creates.last.body["plugins"]
  end

  def test_two_roms_for_one_plugin_are_refused
    fra = cloud(metro: :fra).metro(:fra)
    [{ image: "img", rom: "a:1", plugins: [{ name: "sandbox", rom: "b:1" }] },
     { template: { uuid: "t1" }, rom: "a:1" },
     { template: { uuid: "t1" }, plugins: [{ name: "sandbox", rom: "b:1" }] }].each do |spec|
      err = assert_raises(Error) { fra.sandboxes.create(spec) }

      assert_equal :config, err.kind
    end
    assert_empty posts
  end

  def test_fields_a_sandbox_manages_are_refused
    fra = cloud(metro: :fra).metro(:fra)
    err = assert_raises(Error) { fra.sandboxes.create(image: "img", replicas: 2) }

    assert_equal :config, err.kind
    [{ autostart: false }, { timeout_s: 5 }, { wait_timeout_ms: 5000 }].each do |field|
      assert_match(/boot_within:/,
                   assert_raises(Error) { fra.sandboxes.create(image: "img", **field) }.message)
    end
    assert_empty posts
  end

  def test_client_options_on_a_borrowed_client_are_refused
    ukc = cloud(metro: :fra)
    fra = ukc.metro(:fra)

    refuse = ->(pattern, &call) { assert_match(pattern, assert_raises(Error, &call).message) }

    assert_equal :config, assert_raises(Error) { fra.sandboxes.create(token: "o") }.kind
    refuse.call(/would be ignored/) { fra.sandboxes.get(uuid: "u1", token: "o") }
    refuse.call(/one step earlier/) { fra.sandboxes.create(metros: :dal) }
    refuse.call(/one step earlier/) { fra.sandboxes.create(metro: :dal) }
    refuse.call(/that client's own `sandboxes`/) { fra.sandboxes.get(uuid: "u1", client: ukc) }
    refuse.call(/would be ignored/) { Sandbox.create(client: ukc, token: "o") }
    refuse.call(/drop `client:`/) { Sandbox.connect(uuid: "u1", client: ukc, user_agent: "ua") }

    assert_empty posts
  end

  def test_client_config_tracks_the_client_keywords
    keywords = Unikraft::Cloud::Client.instance_method(:initialize).parameters.map(&:last)

    assert_equal keywords - %i[headers timeout], Unikraft::Cloud::Resources::Sandboxes::CLIENT_CONFIG
  end

  def test_the_static_door_builds_a_client_and_picks_its_metro
    @cloud = FakeCloud.new do |call|
      call.base_url.include?("/plugins/") ? plugin(call) : ok(instances: [INSTANCE])
    end
    sb = Sandbox.create(token: "t", metros: :dal, transport: @cloud.transport, user_agent: "ua/1")

    assert_equal "dal", sb.metro
    assert_equal "https://api.dal.unikraft.cloud", creates.first.base_url
    assert_equal "ua/1", @cloud.transports.first.config[:user_agent]
    err = assert_raises(Error) do
      Sandbox.create(token: "t", metros: %i[dal sin], transport: @cloud.transport)
    end

    assert_match(/single metro/, err.message)
    assert_equal "dal",
                 Sandbox.connect(uuid: "u1", metro: :dal, token: "t",
                                 transport: @cloud.transport).metro
  end

  def test_a_borrowed_client_still_takes_a_metro
    ukc = cloud(metro: :fra)

    assert_equal "dal", Sandbox.create(client: ukc, metros: :dal).metro
  end

  def test_a_missing_token_is_a_config_error
    assert_equal :config, assert_raises(Error) { Sandbox.connect(uuid: "u1", metro: :fra) }.kind
  end

  def test_a_pinned_cluster_serves_the_plugin_endpoint
    url = "https://api.ukp-staging.example.com"
    ukc = cloud(metro: url)
    sb = ukc.metro(:fra).sandboxes.create(image: "img")

    assert(@cloud.calls.all? { |c| c.base_url.start_with?(url) })
    assert_equal "#{url}/v1/instances/u1/plugins/sandbox", sb.base_url
    other = "https://api.other-staging.example.com/v1"
    listed = ukc.metro(:fra).sandboxes.list(base_url: other).first

    assert_equal "https://api.other-staging.example.com/v1/instances/u1/plugins/sandbox",
                 listed.base_url
  end

  def test_a_discovered_metros_own_endpoint_is_used
    found = ok(metros: [{ iata_code: "fra", endpoint: "https://api.fra-2.internal.example" }])
    ukc = cloud(metros: found)
    sb = Sandbox.connect(uuid: "u1", client: ukc)

    assert_equal "fra", sb.metro
    assert_equal "https://api.fra-2.internal.example/v1/instances/u1/plugins/sandbox", sb.base_url
    @cloud.calls.clear
    sb.delete

    assert(@cloud.calls.all? { |c| c.host == "api.fra-2.internal.example" })
    refute_empty @cloud.calls
    made = ukc.metro(:fra).sandboxes.create(image: "img")

    assert_equal sb.base_url, made.base_url
  end

  def test_headers_reach_the_create_and_the_probe
    cloud(metro: :fra).metro(:fra).sandboxes.create(image: "img", headers: { "X-Trace" => "abc" })

    assert_equal(%w[abc abc], @cloud.calls.first(2).map { |c| c.options[:headers]["X-Trace"] })
  end

  # --- readiness -----------------------------------------------------------

  def test_a_failed_wait_deletes_what_create_made_and_says_why
    fra = cloud(metro: :fra) { |call| [404, {}] if call.base_url.include?("/plugins/") }.metro(:fra)
    err = assert_raises(Error) { fra.sandboxes.create(image: "img", ready: FAST) }

    assert_equal :timeout, err.kind
    assert_nil err.status
    assert_match(/the instance is running/, err.message)
    assert_match(/The sandbox was deleted/, err.message)
    assert_includes @cloud.verbs, "DELETE"
    # Each probe gets the time left, so none outlives the deadline.
    probes = @cloud.calls.select { |c| c.path == "/commands" }

    # (Within float rounding of the deadline arithmetic.)
    assert(probes.all? { |c| c.options[:timeout] <= FAST[:within] + 1e-6 })
  end

  def test_a_failed_wait_on_get_deletes_nothing
    fra = cloud(metro: :fra) { |call| [404, {}] if call.base_url.include?("/plugins/") }.metro(:fra)
    err = assert_raises(Error) { fra.sandboxes.get(uuid: "u1", ready: FAST) }

    assert_equal :timeout, err.kind
    refute_match(/deleted/, err.message)
    refute_includes @cloud.verbs, "DELETE"
  end

  def test_an_instance_that_never_ran_is_diagnosed_as_a_pull
    stopped = { uuid: "u1", state: "stopped", image: "my-org/base:latest",
                plugins: [{ name: "sandbox", rom: "plugins/sandbox:typo" }] }
    fra = cloud(metro: :fra, instance: stopped.merge(stop_reason: 0b00100)) do |call|
      [404, {}] if call.base_url.include?("/plugins/")
    end.metro(:fra)
    message = assert_raises(Error) { fra.sandboxes.create(image: "img", ready: FAST) }.message

    assert_match(/never started/, message)
    assert_includes message, "`my-org/base:latest`"
    assert_includes message, "`plugins/sandbox:typo`"
    refute_match(/console log/, message)
    [{ start_count: 1 }, { started_at: "2026-01-01T00:00:00Z" },
     { stop_reason: 0b00011 }].each do |ran|
      fra = cloud(metro: :fra, instance: stopped.merge(ran, exit_code: 1)) do |call|
        [404, {}] if call.base_url.include?("/plugins/")
      end.metro(:fra)
      message = assert_raises(Error) { fra.sandboxes.create(image: "img", ready: FAST) }.message

      assert_match(/console log/, message)
      assert_match(/exited with code 1/, message)
    end
  end

  def test_the_create_block_deletes_the_sandbox_however_it_ends
    fra = cloud(metro: :fra).metro(:fra)

    assert_equal(:done, fra.sandboxes.create { |sb| sb.uuid && :done })
    assert_equal "DELETE", @cloud.calls.last.verb
    assert_raises(RuntimeError) { fra.sandboxes.create { raise "boom" } }
    assert_equal "DELETE", @cloud.calls.last.verb
  end

  def test_a_block_that_deleted_the_sandbox_itself_is_not_an_error
    gone = { status: "error", message: "Failed to perform all operations",
             data: { instances: [{ uuid: "u1", status: "error", error: 8 }] } }
    fra = cloud(metro: :fra) do |call|
      gone if call.verb == "DELETE" && !call.base_url.include?("/plugins/")
    end
          .metro(:fra)

    assert_equal 404, assert_raises(Error) { fra.sandboxes.create.delete }.status
    assert_equal(:ok, fra.sandboxes.create { :ok })
  end

  # --- reading -------------------------------------------------------------

  def test_get_resolves_the_plugin_name
    fra = cloud(metro: :fra, instance: { uuid: "u1", plugins: [{ name: "mine" }] }).metro(:fra)

    assert_equal "mine", fra.sandboxes.get(uuid: "u1").plugin_name
    assert_equal 404, assert_raises(Error) {
      fra.sandboxes.get(uuid: "u1", plugin_name: "x")
    }.status
    fra = cloud(metro: :fra,
                instance: { uuid: "u1",
                            plugins: [{ name: "a" }, { name: "b" }] }).metro(:fra)

    assert_equal :config, assert_raises(Error) { fra.sandboxes.get(uuid: "u1") }.kind
    fra = cloud(metro: :fra, instance: { uuid: "u1", plugins: [] }).metro(:fra)

    assert_equal 404, assert_raises(Error) { fra.sandboxes.get(uuid: "u1") }.status
  end

  def test_list_is_the_instance_list_filtered_by_plugin
    instances = [INSTANCE, { uuid: "u2", plugins: [{ name: "other" }] }, { uuid: "u3" }]
    fra = cloud(metro: :fra) { |call| ok(instances:) if call.path == "/v1/instances" }.metro(:fra)

    assert_equal %w[u1], fra.sandboxes.map(&:uuid)
    assert_equal %w[u2], fra.sandboxes.list(plugin_name: "other").map(&:uuid)
    assert_equal "true", @cloud.calls.last.params["details"]
  end

  def test_the_instance_underneath_is_a_lazy_handle
    sb = cloud(metro: :fra).metro(:fra).sandboxes.create(ready: false)
    @cloud.calls.clear
    inst = sb.instance

    assert_empty @cloud.calls
    assert_equal "running", inst.state
    assert_equal({ "uuid" => "u1", "details" => "true" }, @cloud.calls.last.params)
  end

  # --- commands ------------------------------------------------------------

  def sandbox(&)
    cloud(metro: :fra, &).metro(:fra).sandboxes.create(ready: false).tap { @cloud.calls.clear }
  end

  def test_run_returns_the_output_and_deletes_the_record
    @exitcode = 0
    res = sandbox.run("echo hi", cwd: "/tmp", env: { "A" => "1" })

    assert_equal ["c1", "hi\n", "", 0], [res.uuid, res.stdout, res.stderr, res.exitcode]
    assert_predicate res, :success?
    assert_equal({ "cmd" => "echo hi", "cwd" => "/tmp", "env" => { "A" => "1" } },
                 @cloud.calls.first.body)
    assert_equal %w[POST POST GET GET DELETE], @cloud.verbs
    # The wait without a timeout must not be cut short by the transport's.
    assert_nil @cloud.calls[1].options.fetch(:timeout)
  end

  def test_several_arguments_are_an_argument_vector
    @exitcode = 3
    sb = sandbox
    res = sb.run("sh", "-c", "exit 3", keep: true)

    assert_equal ["sh", "-c", "exit 3"], @cloud.calls.first.body["cmd"]
    refute_predicate res, :success?
    refute_includes @cloud.verbs, "DELETE"
    assert_raises(ArgumentError) { sb.spawn }
  end

  def test_a_timed_out_run_keeps_the_command
    res = sandbox.run("sleep 100", within: 1)

    assert_nil res.exitcode
    assert_equal %w[POST POST GET GET], @cloud.verbs
    assert_equal({ "timeout_s" => 1 }, @cloud.calls[1].body)
    assert_equal 11, @cloud.calls[1].options[:timeout]
    @cloud.calls.clear
    sandbox.command("c1").wait(within: 1, timeout: 3)

    assert_equal 3, @cloud.calls.last.options[:timeout]
  end

  def test_a_plugin_error_is_the_sdks_own_error
    sb = sandbox do |call|
      [500, { status: "error", message: "boom" }] if call.verb == "POST" && call.path == "/commands"
    end
    err = assert_raises(Error) { sb.run("true") }

    assert_equal [:http, 500], [err.kind, err.status]
  end

  def test_a_command_reads_like_an_io
    cmd = sandbox.spawn("cat")
    cmd.write("hi\n").close_write.signal(:TERM)

    assert_equal [{ "data" => ["hi\n"].pack("m0") }, { "data" => "", "eof" => true },
                  { "signal" => "TERM" }], @cloud.calls.drop(1).map(&:body)
    assert_equal "hi\n", cmd.wait.logs.stdout
    assert_equal "\x00\xFF".b, cmd.read(:stdout, offset: -2)
    assert_equal "bytes=-2", @cloud.calls.last.options[:headers]["Range"]
    cmd.read(:stdout, offset: 1, limit: 2)

    assert_equal "bytes=1-2", @cloud.calls.last.options[:headers]["Range"]
  end

  def test_an_unusable_range_never_reaches_the_wire
    cmd = sandbox.command("c1")

    [{ limit: 0 }, { limit: 2.5 }, { offset: Float::NAN }, { offset: -1, limit: 1 }].each do |range|
      assert_equal :config, assert_raises(Error) { cmd.read(:stdout, **range) }.kind
    end
    assert_empty @cloud.calls
  end

  def test_commands_lists_every_command
    sb = sandbox

    assert_equal %w[c1 c2], sb.commands.map(&:uuid)
    assert_equal "c9", sb.command("c9").uuid
  end

  # --- files ---------------------------------------------------------------

  def test_files_send_text_as_utf8_and_bytes_as_base64
    files = sandbox.files
    files.write("/a", "héllo")
    files.write("/b", "\x00\xFF".b, append: true)
    files.upload("/dir", "c.txt", StringIO.new("io"), parents: false)
    files.mkdir("/x/y")

    assert_equal [{ "path" => "/a", "append" => false, "encoding" => "utf-8", "data" => "héllo" },
                  { "path" => "/b", "append" => true, "encoding" => "base64", "data" => "AP8=" },
                  { "path" => "/dir", "filename" => "c.txt", "parents" => false,
                    "encoding" => "utf-8", "data" => "io" },
                  { "path" => "/x/y", "parents" => true }], @cloud.calls.map(&:body)
    assert_equal %w[/fs/write /fs/write /fs/upload /fs/mkdir], @cloud.paths
    assert_equal "\x00\x01\xFE\xFF".b, files.read("/bin")
    assert_equal({ "path" => "/bin" }, @cloud.calls.last.body)
  end
end
