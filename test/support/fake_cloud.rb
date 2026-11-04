# frozen_string_literal: true

require "json"
require "uri"

# An in-memory Unikraft Cloud: a transport builder for `transport:` that
# records every call and answers through a routing block. Fan-out runs on
# threads, so answers are routed per call rather than queued in order.
#
#   cloud = FakeCloud.new { |call| FakeCloud.ok(instances: [{ name: "web" }]) }
#   ukc = Unikraft::Cloud.new(token: "t", metro: :fra, transport: cloud.transport)
#
# The block returns the JSON body, or `[status, body]` for a non-2xx answer.
class FakeCloud
  Call = Struct.new(:verb, :base_url, :path, :params, :body, :options, keyword_init: true) do
    # `https://api.fra.unikraft.cloud` -> `fra`
    def metro = URI(base_url).host.split(".")[1]
    def host = URI(base_url).host
    def url = base_url + path
  end

  # One transport per base URL, as the session builds them.
  class Transport
    attr_reader :base_url, :config

    def initialize(cloud, base_url, config)
      @cloud = cloud
      @base_url = base_url
      @config = config
    end

    def request(method:, path:, query: nil, body: nil, headers: nil, **options)
      @cloud.dispatch(Call.new(verb: method.to_s.upcase, path:,
                               base_url: options[:base_url] || @base_url,
                               params: FakeCloud.params(query),
                               body: body.nil? ? nil : JSON.parse(JSON.generate(body)),
                               options: options.merge(headers:).compact))
    end

    def close = @cloud.closed << @base_url
  end

  attr_reader :calls, :closed, :transports

  def self.ok(data = {}) = { status: "success", op_time_us: 1, data: }

  def self.metros(*codes)
    ok(metros: codes.map do |c|
      { uuid: "uuid-#{c}", name: c.to_s, iata_code: c.to_s, endpoint: "https://api.#{c}.unikraft.cloud" }
    end)
  end

  def self.failure(status) = [status, { status: "error", op_time_us: 1, errors: [{ status: }] }]

  # The query as the URL carries it: nil dropped, arrays joined.
  def self.params(query)
    (query || {}).compact.to_h { |k, v| [k.to_s, Array(v).join(",")] }
  end

  def initialize(&route)
    @route = route
    @calls = []
    @closed = []
    @transports = []
    @mutex = Mutex.new
  end

  def transport
    lambda do |base_url:, **config|
      Transport.new(self, base_url, config).tap { |t| @mutex.synchronize { @transports << t } }
    end
  end

  def dispatch(call)
    @mutex.synchronize { @calls << call }
    answer = @route.call(call)
    status, body = answer.is_a?(Array) ? answer : [200, answer]
    json = JSON.parse(JSON.generate(body), symbolize_names: true)
    return json if status < 300

    raise Unikraft::Cloud::Error.new("HTTP #{status}", kind: :http, status:,
                                                       errors: json[:errors], body: json)
  end

  def paths = calls.map(&:path)
  def verbs = calls.map(&:verb)

  # A developer's real UKC_METRO or UKC_TOKEN would change what the porcelain
  # tests exercise, so they are cleared around each test.
  module Helpers
    def setup
      super
      @saved_env = ENV.to_h.slice("UKC_METRO", "UKC_TOKEN")
      ENV.delete("UKC_METRO")
      ENV.delete("UKC_TOKEN")
    end

    def teardown
      ENV.delete("UKC_METRO") # a test may have set one the environment lacked
      ENV.delete("UKC_TOKEN")
      @saved_env.each { |k, v| ENV[k] = v }
      super
    end

    def ok(data = {}) = FakeCloud.ok(data)

    # A client over a FakeCloud routed by the block; the cloud is @cloud.
    def client(**, &)
      @cloud = FakeCloud.new(&)
      Unikraft::Cloud.new(token: "t", transport: @cloud.transport, **)
    end

    # Answers as if every metro listed holds a resource under `key`, and
    # the control plane reports those metros.
    def everywhere(codes, key: :instances, **opts)
      client(**opts) do |call|
        next FakeCloud.metros(*codes) if call.path == "/v1/metros"

        ok(key => [{ uuid: "u-#{call.metro}", name: "web", state: "running" }])
      end
    end
  end
end
