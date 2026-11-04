# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fake_server"

class HttpTest < Minitest::Test
  ApiClient = Unikraft::Cloud::Core::ApiClient
  Error = Unikraft::Cloud::Error

  def setup
    @server = FakeServer.new
    @client = ApiClient.new(base_url: "#{@server.url}//", token: "tok", proxy_from_env: false,
                            headers: { "X-Default" => "d" })
  end

  def teardown
    @server.close
  end

  def test_request_sends_bearer_token_query_and_parses_json
    @server.respond(body: '{"status":"success","data":{"n":1}}')
    res = @client.request(method: :get, path: "/v1/instances",
                          query: { name: %w[a b], count: 2, details: true, from: nil })

    assert_equal({ status: "success", data: { n: 1 } }, res)
    req = @server.last_request

    assert_equal "GET", req.verb
    assert_equal "/v1/instances", req.path
    assert_equal "name=a&name=b&count=2&details=true", req.query
    assert_equal "Bearer tok", req.headers["authorization"]
    assert_equal "application/json", req.headers["accept"]
    assert_equal "d", req.headers["x-default"]
    assert_match(/\Aunikraft-cloud-ruby/, req.headers["user-agent"])
  end

  def test_request_sends_json_body_and_per_call_headers
    @server.respond(body: "")
    res = @client.request(method: "PATCH", path: "/v1/x", body: [{ name: "a" }],
                          headers: { "X-Default" => "over", "Authorization" => "Bearer other" })

    assert_nil res
    req = @server.last_request

    assert_equal "PATCH", req.verb
    assert_equal '[{"name":"a"}]', req.body
    assert_equal "application/json", req.headers["content-type"]
    assert_equal "over", req.headers["x-default"]
    assert_equal "Bearer other", req.headers["authorization"]
  end

  def test_refuses_a_body_on_get_and_head
    %i[get head].each do |verb|
      err = assert_raises(Error) { @client.request(method: verb, path: "/x", body: {}) }

      assert_equal :config, err.kind
    end
    assert_empty @server.requests
  end

  def test_per_call_base_url
    other = FakeServer.new.respond(body: "{}")
    @client.request(method: :get, path: "/v1/x", base_url: "#{other.url}/")

    assert_equal "/v1/x", other.last_request.path
    assert_empty @server.requests
  ensure
    other&.close
  end

  def test_rejects_unknown_options
    assert_raises(ArgumentError) { @client.request(method: :get, path: "/", signal: 1) }
  end

  # The duck type the generated plugin gems call; see CONTRIBUTING.md.
  def test_satisfies_the_plugin_transport_contract
    contract = [%i[keyreq method], %i[keyreq path], %i[key query], %i[key body], %i[key headers],
                %i[keyrest options]]
    %i[request bytes stream].each do |name|
      params = ApiClient.instance_method(name).parameters - [%i[block block]]

      assert_equal contract, params, "ApiClient##{name}"
    end
  end

  def test_query_accepts_string_keys
    @server.respond(body: "{}")
    @client.request(method: "GET", path: "/x", query: { "uuid" => %w[a b] })

    assert_equal "uuid=a&uuid=b", @server.last_request.query
  end

  def test_http_error_carries_the_envelope
    @server.respond(status: 404,
                    body: '{"status":"error","message":"gone","errors":[{"status":404}]}')
    err = assert_raises(Error) { @client.request(method: :get, path: "/v1/x") }

    assert_equal :http, err.kind
    assert_equal 404, err.status
    assert_equal "gone", err.message
    assert_equal [{ status: 404 }], err.errors
  end

  def test_http_error_with_non_json_body
    @server.respond(status: 502, body: "<html>bad gateway</html>")
    err = assert_raises(Error) { @client.request(method: :get, path: "/v1/x") }

    assert_equal :http, err.kind
    assert_equal 502, err.status
    assert_equal "<html>bad gateway</html>", err.body
    assert_kind_of JSON::ParserError, err.cause
  end

  def test_parse_error_on_success
    @server.respond(body: "not json")
    err = assert_raises(Error) { @client.request(method: :get, path: "/v1/x") }

    assert_equal :parse, err.kind
    assert_equal 200, err.status
  end

  def test_network_error
    port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
    client = ApiClient.new(base_url: "http://127.0.0.1:#{port}", proxy_from_env: false)
    err = assert_raises(Error) { client.request(method: :get, path: "/") }

    assert_equal :network, err.kind
    assert_nil err.status
    assert_kind_of SystemCallError, err.cause
  end

  def test_timeout_is_a_network_error
    client = ApiClient.new(base_url: "http://10.255.255.1", proxy_from_env: false)
    err = assert_raises(Error) { client.request(method: :get, path: "/", timeout: 0.05) }

    assert_equal :network, err.kind
  end

  def test_bytes_returns_the_body_verbatim
    @server.respond(body: "\x00\x01\xFF".b,
                    headers: { "Content-Type" => "application/octet-stream" })
    out = @client.bytes(method: :get, path: "/file")

    assert_equal "\x00\x01\xFF".b, out
    assert_equal Encoding::BINARY, out.encoding
    assert_equal "application/octet-stream", @server.last_request.headers["accept"]
  end

  def test_bytes_error_decodes_the_envelope
    @server.respond(status: 410, body: "")
    err = assert_raises(Error) { @client.bytes(method: :get, path: "/file") }

    assert_equal 410, err.status
    assert_equal "", err.body
  end

  def test_stream_yields_each_event
    @server.respond(chunks: [": keep-alive\n\n", "data: {\"a\":", "1}\n\ndata: {\"a\":2}\r\n\r\n",
                             "event: x\ndata: {\"a\":\ndata: 3}"])
    events = []
    @client.stream(method: :post, path: "/v1/auth/check", body: {}) { |e| events << e }

    assert_equal [{ a: 1 }, { a: 2 }, { a: 3 }], events
    assert_equal "text/event-stream", @server.last_request.headers["accept"]
  end

  def test_stream_without_a_block_is_an_enumerator
    @server.respond(chunks: ["data: 1\n\ndata: 2\n\n"])

    assert_equal [1, 2], @client.stream(method: :get, path: "/s").to_a
  end

  def test_stream_bad_event_is_a_parse_error
    @server.respond(chunks: ["data: nope\n\n"])
    err = assert_raises(Error) { @client.stream(method: :get, path: "/s") { nil } }

    assert_equal :parse, err.kind
  end

  def test_stream_http_error
    @server.respond(status: 401, body: '{"message":"unauthorized"}')
    err = assert_raises(Error) { @client.stream(method: :get, path: "/s") { nil } }

    assert_equal 401, err.status
    assert_equal "unauthorized", err.message
  end

  def test_reuses_one_connection_for_sequential_calls
    3.times { @server.respond(body: "{}") }
    @client.request(method: :get, path: "/a")
    @client.bytes(method: :get, path: "/b")
    @client.request(method: :post, path: "/c", body: {})

    assert_equal 1, @server.accepts
  end

  def test_concurrent_calls_never_share_a_connection
    8.times { @server.respond(body: '{"ok":true}', delay: 0.1) }
    2.times do
      results = Array.new(4) { Thread.new { @client.request(method: :get, path: "/") } }
                     .map(&:value)

      assert_equal [{ ok: true }] * 4, results
      # The second round reuses the first round's connections.
      assert_equal 4, @server.accepts
    end
  end

  def test_a_stale_reused_connection_is_resent_once_on_a_fresh_one
    @server.respond(body: "{}").respond(drop: true).respond(body: '{"n":2}')
    @client.request(method: :get, path: "/")

    assert_equal({ n: 2 }, @client.request(method: :get, path: "/x"))
    assert_equal [1, 1, 2], @server.requests.map(&:conn)
  end

  def test_a_non_idempotent_request_is_never_resent
    %i[post patch].each do |verb|
      server = FakeServer.new.respond(body: "{}").respond(drop: true)
      client = ApiClient.new(base_url: server.url, proxy_from_env: false)
      client.request(method: :get, path: "/")
      err = assert_raises(Error) { client.request(method: verb, path: "/x", body: {}) }

      assert_equal :network, err.kind
      assert_equal 2, server.requests.size, verb
    ensure
      server&.close
    end
  end

  def test_a_fresh_connection_is_never_resent
    @server.respond(drop: true)
    err = assert_raises(Error) { @client.request(method: :get, path: "/") }

    assert_equal :network, err.kind
    assert_kind_of EOFError, err.cause
    assert_equal 1, @server.requests.size
  end

  def test_the_resend_is_not_resent_again
    @server.respond(body: "{}").respond(drop: true).respond(drop: true)
    @client.request(method: :get, path: "/")
    err = assert_raises(Error) { @client.request(method: :get, path: "/") }

    assert_equal :network, err.kind
    assert_equal 3, @server.requests.size
  end

  def test_a_timeout_on_a_reused_connection_is_not_resent
    @server.respond(body: "{}").respond(body: "{}", delay: 0.5)
    @client.request(method: :get, path: "/")
    err = assert_raises(Error) { @client.request(method: :get, path: "/", timeout: 0.05) }

    assert_equal :network, err.kind
    assert_kind_of Net::ReadTimeout, err.cause
    assert_equal 2, @server.requests.size
  end

  def test_idle_connections_expire
    @client.instance_variable_set(:@pool, Unikraft::Cloud::Core::Pool.new(keep_alive: 0.05))
    2.times { @server.respond(body: "{}") }
    @client.request(method: :get, path: "/")
    sleep 0.1
    @client.request(method: :get, path: "/")

    assert_equal 2, @server.accepts
  end

  def test_close_drops_idle_connections_and_the_client_stays_usable
    2.times { @server.respond(body: "{}") }
    @client.request(method: :get, path: "/")
    @client.close
    @client.close

    assert_empty idle_connections
    @client.request(method: :get, path: "/")

    assert_equal 2, @server.accepts
  end

  def test_connection_close_is_honoured
    @server.respond(body: "{}", close: true).respond(body: "{}")
    @client.request(method: :get, path: "/")

    assert_empty idle_connections
    @client.request(method: :get, path: "/")

    assert_equal 2, @server.accepts
  end

  def test_an_http_error_keeps_the_connection
    @server.respond(status: 404, body: "{}").respond(body: "{}")
    assert_raises(Error) { @client.request(method: :get, path: "/") }
    @client.request(method: :get, path: "/")

    assert_equal 1, @server.accepts
  end

  def test_a_stream_left_early_closes_its_connection
    @server.respond(chunks: ["data: 1\n\n", "data: 2\n\n"]).respond(body: "{}")

    assert_equal 1, @client.stream(method: :get, path: "/s").first
    assert_empty idle_connections
    @client.request(method: :get, path: "/")

    assert_equal 2, @server.accepts
  end

  def test_a_finished_stream_returns_its_connection
    @server.respond(chunks: ["data: 1\n\n"]).respond(body: "{}")
    @client.stream(method: :get, path: "/s").to_a
    @client.request(method: :get, path: "/")

    assert_equal 1, @server.accepts
  end

  private

  def idle_connections
    @client.instance_variable_get(:@pool).instance_variable_get(:@idle).values.flatten
  end
end
