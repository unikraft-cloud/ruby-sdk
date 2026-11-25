# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fake_server"
require "unikraft/cloud/plugin/sandbox/api"

# The plugin gems take any transport with the methods their `Transport`
# module lists, called with its keywords. Ruby checks neither ahead of time,
# so this is where a drift between the gem and ApiClient shows up.
class PluginTransportTest < Minitest::Test
  ApiClient = Unikraft::Cloud::Core::ApiClient
  Plugin = Unikraft::Cloud::Plugin::Sandbox::API

  def setup
    @server = FakeServer.new
    @client = ApiClient.new(base_url: "#{@server.url}/v1/instances/u1/plugins/sandbox",
                            token: "tok", proxy_from_env: false)
  end

  def teardown
    @server.close
  end

  def test_api_client_takes_every_transport_method_as_declared
    Plugin::Transport::METHODS.each do |name|
      declared = Plugin::Transport.instance_method(name).parameters
      # `stream` also names its block, which the contract leaves implicit.
      given = ApiClient.instance_method(name).parameters.reject { |param| param.first == :block }

      assert_equal declared, given, "ApiClient##{name} drifted from the plugin transport"
    end
  end

  def test_the_plugin_client_accepts_an_api_client
    api = Plugin.new(@client)

    assert_same @client, api.transport
    assert_raises(TypeError) { Plugin.new(Object.new) }
  end

  def test_a_request_reaches_the_plugin_route
    @server.respond(body: '{"status":"success","data":{"uuid":"c1"}}')
    res = Plugin.new(@client).commands.run_command(body: { cmd: %w[ls -la] },
                                                   headers: { "X-Trace" => "t" }, timeout: 5)

    assert_equal "c1", res.data.uuid
    req = @server.last_request

    assert_equal "/v1/instances/u1/plugins/sandbox/commands", req.path
    assert_equal '{"cmd":["ls","-la"]}', req.body
    assert_equal "t", req.headers["x-trace"]
  end

  def test_raw_bytes_carry_the_range_header
    @server.respond(body: "\x00\xFF".b)
    bytes = Plugin.new(@client).commands.get_raw_command_log(uuid: "c1", stream: "stdout",
                                                             range: "bytes=-2")

    assert_equal "\x00\xFF".b, bytes
    assert_equal Encoding::BINARY, bytes.encoding
    assert_equal "bytes=-2", @server.last_request.headers["range"]
  end
end
