# frozen_string_literal: true

require_relative "../test_helper"

# A transport that records each call and answers with a canned value.
class RecordingTransport
  attr_reader :calls

  def initialize(response = { status: "success" }, events: [])
    @response = response
    @events = events
    @calls = []
  end

  def request(**args)
    @calls << [:request, args]
    @response
  end

  def bytes(**args)
    @calls << [:bytes, args]
    "\x00".b
  end

  def stream(**args, &)
    @calls << [:stream, args]
    @events.each(&)
  end
end

class ApiTest < Minitest::Test
  API = Unikraft::Cloud::API

  def resource_classes
    [API::Platform, API::ControlPlane].flat_map do |surface|
      surface.constants.map { |c| surface.const_get(c) }
             .select { |k| k.is_a?(Class) && k.name.end_with?("Api") }
    end
  end

  # Fill every required keyword with a value that needs escaping in a path.
  def required_args(meth)
    meth.parameters.filter_map { |kind, name| [name, "a b/c"] if kind == :keyreq }.to_h
  end

  def test_every_generated_operation_builds_a_request
    count = 0
    resource_classes.each do |klass|
      klass.public_instance_methods(false).each do |name|
        next if name == :client

        transport = RecordingTransport.new
        api = klass.new(transport)
        meth = api.method(name)
        args = required_args(meth).merge(headers: { "X" => "1" })
        # Only an event stream takes a block; it yields nothing here.
        if meth.parameters.any? { |kind, _| kind == :block }
          api.public_send(name, **args) { nil }
        else
          api.public_send(name, **args)
        end
        kind, args = transport.calls.fetch(0)
        count += 1

        assert_includes %i[request bytes stream], kind
        assert_includes %w[GET POST PUT PATCH DELETE HEAD], args[:method], "#{klass}##{name}"
        assert args[:path].start_with?("/"), "#{klass}##{name}: #{args[:path]}"
        refute_includes args[:path], "{", "#{klass}##{name}: unfilled path parameter"
        refute_includes args[:path], " ", "#{klass}##{name}: unescaped path parameter"
        refute args.key?(:body) && %w[GET HEAD].include?(args[:method]),
               "#{klass}##{name} sends a body on #{args[:method]}"
        assert_equal({ "X" => "1" }, args[:headers], "#{klass}##{name} drops options")
      end
    end

    assert_operator count, :>, 50
  end

  def test_get_instances
    transport = RecordingTransport.new({ status: "success",
                                         data: { instances: [{ name: "web" }] } })
    instances = API::Platform.new(transport).instances
    res = instances.get_instances(name: %w[a b], tags: %w[x y], count: 2, base_url: "https://other")

    assert_kind_of API::Platform::Models::GetInstancesResponse, res
    assert_equal "web", res.data.instances.first.name
    assert_equal [:request, { method: "GET", path: "/v1/instances",
                              query: { uuid: nil, name: %w[a b], details: nil, count: 2, from: nil,
                                       order: nil, sortby: nil, tags: "x,y" },
                              base_url: "https://other" }], transport.calls.first
  end

  def test_update_instances_sends_the_body
    transport = RecordingTransport.new
    body = [{ name: "web", prop: "memory_mb", op: "set", value: 256 }]
    API::Platform.new(transport).instances.update_instances(body:)

    assert_equal({ method: "PATCH", path: "/v1/instances", body: body }, transport.calls.first[1])
  end

  def test_path_parameters_are_escaped
    transport = RecordingTransport.new
    API::Platform.new(transport).instances.get_instance_by_uuid(uuid: "a/b?c")

    assert_equal "/v1/instances/a%2Fb%3Fc", transport.calls.first[1][:path]
  end

  def test_event_streams_yield_models
    transport = RecordingTransport.new(events: [{ type: "start" }])
    audit = API::Platform.new(transport).audit
    events = audit.subscribe_audit_events(events: ["start"]).to_a

    assert_equal [API::Platform::Models::AuditEvent.new(type: "start")], events
    assert_equal :stream, transport.calls.first[0]
  end

  def test_empty_response_is_nil
    assert_nil API::Platform.new(RecordingTransport.new(nil)).instances.get_instances
  end

  def test_enums_are_frozen_constants
    states = API::Platform::Models::InstanceState

    assert_equal "running", states::RUNNING
    assert_includes states::ALL, "stopped"
    assert_predicate states::ALL, :frozen?
  end

  def test_containers
    api = API.new(platform: { base_url: "https://api.fra.unikraft.cloud", token: "t" },
                  controlplane: RecordingTransport.new)

    assert_kind_of API::Platform::InstancesApi, api.platform.instances
    assert_equal "https://api.fra.unikraft.cloud", api.platform.client.base_url
    assert_kind_of API::ControlPlane::MetrosApi, api.controlplane.metros
    assert_same api.platform.client, api.platform.volumes.client
  end
end
