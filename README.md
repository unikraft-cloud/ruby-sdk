# `unikraft-cloud`

The official Ruby SDK for the [Unikraft Cloud][ukc] API.

## Installation

```sh
gem install unikraft-cloud
```

or, with Bundler, in your `Gemfile`:

```ruby
gem "unikraft-cloud"
```

## Quickstart

```ruby
require "unikraft/cloud"

ukc = Unikraft::Cloud.new(token: ENV["UKC_TOKEN"])

# By default the client is account-wide: every metro is asked in parallel and
# the results are merged, each tagged with the metro it came from.
ukc.instances.list(details: true) do |inst|
  puts "#{inst.metro} #{inst.name} #{inst.state}"
end

# Creating a resource happens in one metro, so name it.
fra = ukc.metro(:fra)
instance = fra.instances.create(
  image: "nginx:latest",
  autostart: true,
  memory_mb: 256,
  service_group: {
    services: [{ port: 443, handlers: %w[tls http], destination_port: 80 }]
  }
)

# Operations chain off a handle, so a ref is written once.
instance.wait(state: :running)
ukc.instances.get(name: instance.name).suspend
fra.instances.delete(uuid: instance.uuid)
```

## Authentication

Pass a bearer `token:` to `Unikraft::Cloud.new`, or set the `UKC_TOKEN`
environment variable. Create a token in the
[Unikraft Cloud dashboard][dashboard].

## The client

`Unikraft::Cloud.new(**options)` returns a `Unikraft::Cloud::Client`. Every
option is optional:

| Option               | Default                  | Meaning                                                                    |
| -------------------- | ------------------------ | -------------------------------------------------------------------------- |
| `token:`             | `UKC_TOKEN`              | Bearer token.                                                              |
| `metro:`             | `UKC_METRO`              | One metro (`:fra`) or a full `http(s)://` URL. The target of `create`.     |
| `metros:`            | `:all`, or `[metro]`     | The default scope of reads and bulk operations: `:all`, a metro, or a list. |
| `base_url:`          |                          | An explicit platform API URL; overrides `metro:`.                          |
| `control_plane_url:` | the global control plane | Where metro discovery and `ukc.api.controlplane` go.                       |
| `headers:`           | `{}`                     | Extra headers sent with every request.                                     |
| `timeout:`           | `60`                     | Seconds per connect and read; `nil` waits without limit.                   |
| `proxy_from_env:`    | `true`                   | Honour `http_proxy`/`https_proxy`/`no_proxy`.                              |
| `user_agent:`        | `unikraft-cloud-ruby/…`  | The `User-Agent` header.                                                   |
| `transport:`         |                          | Builds the transport from the transport keywords; see [Runtime support](#runtime-support). |

The client is thread-safe and meant to be long-lived: build one and share it
across threads, rather than one per request. Metro discovery and connections
are shared by everything that comes from it. `close` closes its connections;
a later call reopens what it needs. For a script, the block form closes the
client for you and returns the block's value:

```ruby
count = Unikraft::Cloud.open(metro: :fra) do |ukc|
  ukc.instances.count
end
```

## The two layers: porcelain and plumbing

The SDK is explicitly two layers, and you choose per call which one you are in:

| Layer         | Where                                                         | What you get                                                                     |
| ------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| **Porcelain** | `ukc.instances`, `ukc.volumes`, …                             | Short verbs, no envelope, auto-pagination, metro fan-out, chainable handles      |
| **Plumbing**  | `Unikraft::Cloud::API::Platform`, `Unikraft::Cloud::API::ControlPlane` | The OpenAPI specification as written: `operationId` methods, raw envelope, one metro per call |

The porcelain layer **holds** a plumbing client rather than inheriting from
one, so the two never blur together, and the raw client is always one method
away:

```ruby
# Porcelain: unwrapped, metro-aware.
inst = ukc.instances.get(name: "web")

# Plumbing, from the same client and credentials.
res = ukc.api.platform.instances.get_instances(count: 10, details: true)
res.status          # => "success"
res.data.instances

# Plumbing, per resource (the escape hatch for anything not wrapped yet).
ukc.instances.api.get_instance_logs(name: ["web"])

# Plumbing, standalone: no porcelain involved.
api = Unikraft::Cloud::API::Platform.new(
  base_url: "https://api.fra.unikraft.cloud", token: ENV["UKC_TOKEN"]
)
api.instances.get_instances(count: 10)
```

Plumbing clients are metro-scoped by construction: they talk to whatever
`base_url:` names, and a single call can be redirected with `base_url:`.
Fanning out across metros is the porcelain layer's job.

### Two APIs: platform and control plane

Both Unikraft Cloud APIs defined by our [OpenAPI][openapi] specification are
wrapped:

- **Platform**: metro-scoped resources (instances, volumes, services,
  certificates, autoscale, images). Wrapped idiomatically at the top level;
  raw under `Unikraft::Cloud::API::Platform` and `ukc.api.platform`.
- **Control plane**: the global (non-metro) API for the account, metros,
  images and self-hosted nodes. Raw only, under
  `Unikraft::Cloud::API::ControlPlane` and `ukc.api.controlplane`.

```ruby
ukc.api.controlplane.metros.list_metros.data.metros.each do |metro|
  puts "#{metro.iata_code} #{metro.endpoint}"
end
```

## Metros: one account, many regions

The platform API is per metro, but an account's instances are spread across
them. The porcelain layer treats **the metros in scope** as one namespace:
reads fan out concurrently and are merged, and every result carries the
`metro` it came from.

```ruby
ukc = Unikraft::Cloud.new(token: ENV["UKC_TOKEN"])

# Every metro the account can reach (discovered once, then cached).
ukc.instances.each { |inst| puts "#{inst.metro} #{inst.name}" }

# Explicit scopes; these also skip metro discovery entirely.
ukc.metro(:fra).instances.to_a              # one metro
ukc.metros(:fra, :dal).instances.to_a       # several
ukc.instances.list(metros: %i[fra dal]).to_a # just this call
ukc.instances.list(metros: :all).to_a        # back to everything

# What the account can reach.
ukc.available_metros.each { |m| puts "#{m.metro} #{m.base_url}" }
```

Metros are Symbols or Strings, whichever you have. Set the default scope at
construction, too:

```ruby
Unikraft::Cloud.new                          # all metros (default)
Unikraft::Cloud.new(metro: :fra)             # one metro
Unikraft::Cloud.new(metros: %i[fra dal])     # several
```

`UKC_METRO` acts like `metro:`: setting it pins the client to that metro.
With both `metro:` and `metros:`, `metros:` is the scope and `metro:` stays
the target of `create`.

| Code  | Location            |
| ----- | ------------------- |
| `fra` | Frankfurt, DE       |
| `dal` | Dallas, TX, USA     |
| `sin` | Singapore           |
| `was` | Washington, DC, USA |
| `sfo` | San Francisco, USA  |

Metro discovery asks the control plane and trusts the endpoint it reports, so
new metros work without an SDK upgrade. `Unikraft::Cloud::KNOWN_METROS` lists
the ones known when this version was published.

### Rules the fan-out follows

- **Reads** cover the whole scope. Pages are interleaved in arrival order, so
  a slow metro never holds up a fast one, and each metro fetches its next
  page only as the last one is used up. Leaving early (`first`, `break`)
  stops the metros still in flight. An external enumerator (`next`) left
  midway cannot stop them; they stay parked, sending nothing, so prefer
  `each`, `first` or `lazy`.
- **A name identifies a resource within a metro.** The same name can exist in
  several metros at once, usually because you deployed the same thing
  everywhere, so a name plus a wide scope may match more than one resource.
  See [Names across metros](#names-across-metros).
- **`create` never fans out.** It needs one metro: `create(metro: :dal, ...)`,
  the scope's, or the default metro (`metro:` / `UKC_METRO` / `fra`) when
  the scope is wider. A scope of several named metros must include the
  default; otherwise `create` raises `kind: :config` rather than guess.
- **Bulk operations are bounded by the scope.** Refs are located first and one
  call goes to each metro that matched, so `delete(name: "web")` under a wide
  scope deletes every `web` in scope. Narrow the scope or qualify the ref to
  act on one.
- **The control plane is global**, so it is unaffected by scope.

### Names across metros

Names are scoped to a metro, so the same name can name a different resource
in every metro. Three ways to say what you mean:

```ruby
# 1. Qualify the ref. No search, no discovery: one request.
ukc.instances.get(name: "web", metro: :fra).suspend

# 2. Narrow the scope, which qualifies every ref through it.
ukc.metro(:fra).instances.get(name: "web").suspend

# 3. Address every metro holding it, on purpose.
ukc.instances.where(name: "web").suspend # one result per metro
```

`uuid:` refs rarely need qualifying: a UUID identifies one resource wherever
it lives.

`get` insists on exactly one match, because the next thing you write might be
a mutation. When a ref matches in several metros it raises an
`AmbiguousRefError` carrying the matches, so recovering costs no further
requests:

```ruby
begin
  ukc.instances.get(name: "web").suspend
rescue Unikraft::Cloud::AmbiguousRefError => e
  e.metros  # => ["fra", "dal", "sin"]
  e.matches # the instances themselves, each tagged with #metro
end
```

`where` is the deliberate plural. It locates the matches once, is Enumerable
over them, and runs each operation in the metro that holds each one:

```ruby
web = ukc.instances.where(name: "web")

web.metros                                 # => ["fra", "dal", "sin"]
web.size                                   # => 3
web.each { |inst| puts inst.state }        # the instances
web.suspend                                # one result per metro
web.edit { |e| e.set(memory_mb: 512) }
```

Set operations return Arrays and follow the same partial-failure rule as
reads: the successes ride on the raised `MetroFanoutError` as `results`.
`where` exists on instances, volumes, services and certificates.

### Partial failure

A metro that is unreachable does not throw away the rest of the answer.
Healthy metros are drained first, then a `MetroFanoutError` naming the
failures is raised:

```ruby
begin
  ukc.instances.each { |inst| puts inst.name } # fra, dal, was delivered
rescue Unikraft::Cloud::MetroFanoutError => e
  e.message  # => "1 of 4 metros failed: sin (503)"
  e.failures # => [{ metro: "sin", error: #<Unikraft::Cloud::Error ...> }]
end
```

For a bulk operation, which cannot yield as it goes, the results that did
succeed are attached to the raised error as `results`.

## Lists are lazy Enumerables

`list` returns an `Enumerator` that pages through every metro in scope on
demand, or takes a block (and then returns the client, like `each`).
`tags:` filters instances and volumes, which the API filters by tag. Each
resource client is itself `Enumerable` over
every resource in scope (with details), so the usual methods just work:

```ruby
ukc.instances.list(details: true, tags: ["prod"]).each { |i| puts i.name }
ukc.instances.list(page_size: 50).first(10)

ukc.instances.select { |i| i.state == "running" }
ukc.instances.count
ukc.volumes.map(&:size_mb).sum
```

Results are models: one reader per field, `#[]` for any key, `#to_h`, and
pattern matching, including the `metro` tag:

```ruby
case ukc.instances.first
in { state: "running", metro: "fra" } then puts "running in Frankfurt"
in { name: } then puts "#{name} is elsewhere"
end
```

## Chainable handles

Single-resource operations return a **handle**: a reference to one resource in
one metro. `get` sends nothing; reading an attribute resolves the handle once
and memoizes the resource:

```ruby
web = ukc.instances.get(name: "web") # no request yet
web.state                            # => "running" (located and read once)
web.running?                         # => true (no further request)
web.reload                           # read again, in place
```

Ruby has no `await`, and a lazy mutation that nobody forced would silently
never run. So mutations run **immediately** and return a new handle carrying
what that endpoint reported, at the same location, so calls still chain:

```ruby
ukc.instances.get(name: "web").suspend.state # => "standby"
ukc.instances.get(name: "web").update(memory_mb: 512)

ukc.metro(:fra).instances
   .create(image: "nginx:latest")
   .wait(state: :running, within: 30)
   .logs(offset: -4096)

ukc.volumes.get(name: "data").attach(attach_to: { name: "web" }, at: "/data")
```

Each step runs once. What locating costs depends on the scope:

| Ref and scope                     | `get(...).suspend`                                                |
| --------------------------------- | ----------------------------------------------------------------- |
| `name:` and `metro:`, any scope   | 1 request: the suspend. The ref says where.                       |
| `name:`, one metro in scope       | 1 request: the scope says where.                                  |
| `name:`, many metros              | Locate first (one concurrent read per metro), then suspend where it lives, or raise `AmbiguousRefError` if several match. |

Handles also answer where they landed, and a mutating step carries what its
endpoint reports (`suspend` reports `uuid`, `name`, `state` and
`previous_state`, not a full instance; read it with `handle[:previous_state]`,
and a declared attribute the reply leaves out, such as `memory_mb`, is read
once from the platform on first use):

```ruby
web = ukc.instances.get(name: "web")
web.metro    # => "dal"
web.location # => #<data Location ref=..., metro="dal", base_url="https://api.dal.unikraft.cloud">
web.to_h     # the resource as a Hash
```

A handle is meant for one thread; the client behind it is shared.

Every idiomatic method is also available in non-chained form, the ref keys
(`name:`, `uuid:`, `metro:`) locating the resource and the rest going to the
operation: `ukc.instances.logs(name: "web", offset: -4096)` is exactly
`get(name: "web").logs(offset: -4096)`. `start`, `stop`, `suspend` and
`delete` on the collection are bulk operations instead; see [Refs](#refs).

## Updating a resource

The API models an update as a list of `{ prop:, op:, value: }` triples. That
is the plumbing. Idiomatically you pass **keyword arguments** and the op is
worked out for you: a value sets the property, `nil` removes it, and an
omitted property is left alone, following JSON Merge Patch:

```ruby
ukc.instances.get(name: "web").update(memory_mb: 512, vcpus: 2)
ukc.instances.get(name: "web").update(env: { LOG_LEVEL: "debug" })
ukc.instances.get(name: "web").update(autokill: nil) # remove it
ukc.volumes.get(name: "data").update(size_mb: 2048)
ukc.services.get(name: "web").update(soft_limit: 5, hard_limit: 20)
```

`image` takes the same string shorthand as `create`. `headers:` and
`timeout:` are always call options, never properties:
`update(memory_mb: 512, timeout: 10)`.

When `set` is not what you mean (merging into a property, or removing
individual members), stage the operations with `edit` and send them as one
request, from a block or chained:

```ruby
ukc.instances.get(name: "web").edit do |e|
  e.set(memory_mb: 512)
  e.add(env: { LOG_LEVEL: "debug" }, tags: ["prod"])
  e.remove(env: ["OLD_FLAG"], tags: ["staging"])
end

ukc.instances.get(name: "web").edit
   .set(memory_mb: 512)
   .remove(env: ["OLD_FLAG"])
   .apply

# `nil` in remove removes the property outright, not just some members.
ukc.services.edit(name: "web") { |e| e.remove(domains: nil) }
```

`remove` is the API's `del`. The block form applies when the block returns;
the chained form applies on `apply`. Both return a handle like any other
operation, so chaining continues:

```ruby
ukc.metro(:fra).instances
   .edit(name: "web")
   .set(memory_mb: 1024)
   .apply
   .wait(state: :running)
```

Both forms are one request, and both are available without a handle
(`ukc.instances.update(name: "web", memory_mb: 512)`,
`ukc.instances.edit(name: "web")`). The raw triples still work as an escape
hatch:
`ukc.instances.update({ name: "web" }, [{ prop: "memory_mb", op: "set", value: 512 }])`.

## Refs

Every operation on an existing resource takes a **ref**: either `name:` or
`uuid:`, never both (passing both raises `ArgumentError`). The API validates
each identifier it is given, so a name sent in the `uuid` filter fails with
`Invalid uuid '<name>'`: the ref makes you state which kind you hold, and only
that field is sent.

```ruby
ukc.instances.get(name: "web")
ukc.instances.get(uuid: "550e8400-e29b-41d4-a716-446655440000")

# A name belongs to a metro, so it can be qualified; see "Names across metros".
ukc.instances.get(name: "web", metro: :fra)

# Bulk operations take one ref, as keywords or a Hash, or an Array of them.
ukc.instances.stop(name: "web")
ukc.instances.stop([{ name: "web" }, { uuid: "550e8400-e29b-41d4-a716-446655440000" }])
```

## Idiomatic methods

| Resource           | Methods                                                                                                   |
| ------------------ | --------------------------------------------------------------------------------------------------------- |
| `ukc.instances`    | `create`, `get`, `where`, `list`, `each` (Enumerable), `update`, `edit`, `delete`, `start`, `stop`, `suspend`, `wait`, `logs`, `metrics`, `history` |
| `ukc.volumes`      | `create`, `get`, `where`, `list`, `each`, `update`, `edit`, `delete`, `attach`, `detach`                   |
| `ukc.services`     | `create`, `get`, `where`, `list`, `each`, `update`, `edit`, `delete`                                       |
| `ukc.certificates` | `create`, `get`, `where`, `list`, `each`, `update`, `delete`                                               |
| `ukc.users`        | `quotas`, `quotas(uuid:)`                                                                                 |
| `ukc.metro(m).sandboxes` | `create` (with a block), `get`, `list`, `each`; see [Sandboxes](#sandboxes)                           |

Handles add the per-resource operations: `reload`, `start`, `stop`,
`suspend`, `delete`, `update`, `edit`, `wait`, `logs`, `metrics`, `history`
and the state predicates (`running?`, `stopped?`, `standby?`, …) on an
instance; `attach`, `detach`, `update`, `edit`, `delete` on a volume;
`update`, `edit` and `delete` on a service group; `update` (with `chain:` and
`pkey:`) and `delete` on a certificate. Every handle has `metro`, `location`,
`model`, `to_h`, `[]` and a reader per attribute.

Anything not listed (autoscale, the image registry, node information, the
whole control plane) is reachable raw via `ukc.api.platform` and
`ukc.api.controlplane`:

```ruby
ukc.api.platform.autoscale.get_autoscale_configurations(name: ["web"])
ukc.api.platform.images.get_images
```

See [`examples/`](./examples) for complete programs.

## Sandboxes

A sandbox is a virtual machine that runs whatever command you hand it: an
instance with the sandbox plugin attached. It lives in one metro, so it hangs
off a metro scope. With a block, `create` deletes the sandbox when the block
returns, however it returns:

```ruby
Unikraft::Cloud.open do |ukc|
  ukc.metro(:fra).sandboxes.create(memory_mb: 1024) do |sb|
    res = sb.run("echo hello")             # a shell line
    res.stdout                             # => "hello\n"
    sb.run("ls", "-la", cwd: "/tmp").success?  # an argument vector

    sb.files.write("/work/a.txt", "hello\n")
    sb.files.read("/work/a.txt")           # => "hello\n" (binary)

    sb.instance.update(memory_mb: 2048)    # it is a real instance
  end
end
```

`Unikraft::Cloud::Sandbox.create` and `.connect` do the same without a
client in hand: they build one from `token:` (or `UKC_TOKEN`), `metro:` (or
`UKC_METRO`) and the other `Unikraft::Cloud.new` options, or borrow one as
`client:`.

- **Creating.** The spec is what `instances.create` takes, plus `rom:` and
  `plugin_name:`. The image defaults to `UKC_SANDBOX_IMAGE`, else
  `debian-slim:latest`; memory to 2048 MB; `autokill` to five minutes of
  stopped time. `create` waits for the machine (`boot_within:`, 30 s) and
  then for the plugin (`ready: { within: 60 }`). A failed wait deletes the
  machine and names the likely cause; `ready: false` skips the waits and
  keeps a broken sandbox for inspection. A `template:`, `branch_from:` or
  `checkpoint:` brings its own image, memory and plugin.
- **Reattaching.** `sandboxes.get(uuid:)` and `Sandbox.connect(uuid:,
  metro:)` never wait and never delete; call `sb.ready` after a start or a
  resume. `sandboxes.list` and `each` are the instance list, filtered to
  those carrying the plugin.
- **Commands.** `run` waits and returns a `Result` (`stdout`, `stderr`,
  `exitcode`, `success?`); a failing command is not an exception, and a
  `within:` that runs out leaves `exitcode` nil and the command running.
  `spawn` returns a `Command` at once:

  ```ruby
  cat = sb.spawn("cat", cwd: "/work", env: { "LANG" => "C" })
  cat.write("first line\n").close_write    # standard input, like an IO
  cat.wait(within: 10)
  cat.logs.stdout                          # => "first line\n"
  cat.read(:stdout, offset: -4096)         # the raw tail, binary
  sb.spawn("sleep 600").signal(:TERM)
  ```

- **Files.** `sb.files.read`, `write` (`append:`), `mkdir` (parents by
  default) and `upload(dir, filename, data)`. Data is a String or anything
  with `read`; a binary String travels as bytes, any other as UTF-8 text.

As with `instance.wait`, `within:` is how long a wait may take, and
`timeout:` is only ever the HTTP timeout of a request. A request held open
for a wait has its read timeout stretched to cover it, unless `timeout:`
says otherwise.

`sb.api` is the raw plugin client (`sb.api.commands`, `sb.api.fs`) from the
`unikraft-cloud-plugin-sandbox-api` gem, pinned to this sandbox.

## Errors

Any network failure or non-2xx response raises a `Unikraft::Cloud::Error`:

```ruby
begin
  ukc.metro(:fra).instances.get(name: "does-not-exist").state
rescue Unikraft::Cloud::Error => e
  warn [e.kind, e.status, e.message, e.errors].inspect
end
```

`e.kind` says which layer failed:

| `kind`     | Meaning                                                                                                              |
| ---------- | -------------------------------------------------------------------------------------------------------------------- |
| `:http`    | The server answered with a non-2xx status. `e.status` and `e.errors` carry the detail.                                |
| `:network` | The request never got an answer: a refused connection, a reset, a DNS miss, an unreachable proxy.                     |
| `:parse`   | The server answered, but the body is not the JSON the operation expects.                                             |
| `:fanout`  | A multi-metro operation that partly failed, or an unusable scope; see `MetroFanoutError` above.                       |
| `:config`  | The call could never be sent as configured: two options that contradict each other, or a body on a `GET`.            |
| `:timeout` | A wait ran out of time. It carries no `status`, because no single request failed; the last failure is in `e.cause`.  |

`AmbiguousRefError` and `MetroFanoutError` are subclasses, so one
`rescue Unikraft::Cloud::Error` covers everything the SDK raises. An invalid
argument, such as a ref with both `name:` and `uuid:`, raises `ArgumentError`
instead.

### Waiting

The transport sends each request exactly once. It has no retries, and nothing
in the SDK retries a call you made.

Waiting is a separate, explicit step, and it takes one of two shapes:

- **The server waits.** `instance.wait(state: :running, within: 30)`
  forwards the state and the deadline (in seconds; `-1` waits indefinitely)
  to the platform, which holds the connection open. One request; the read
  timeout of that request is stretched to outlive the wait. `timeout:` is
  the HTTP timeout, as on every other call.
- **The SDK polls.** Where the platform has nothing to hold open, the SDK
  asks again on a schedule. `Unikraft::Cloud::Core::Ready.wait_until_ready`
  owns that loop: the delay doubles from 100 ms to 2 s with jitter, and the
  deadline is 60 s. Only a failure that can still change is worth another
  probe: a network fault, or a `404`/`502`/`503`/`504`. A `401` or a `403` is
  raised at once, so a rejected token reports itself instead of timing out.

Both raise on failure rather than returning. A poll that runs out of time
raises `kind: :timeout`.

## Self-hosted and staging deployments

`metro:` (and `UKC_METRO`) also accepts a full `http(s)://` base URL, which is
used verbatim instead of being expanded into
`https://api.<metro>.unikraft.cloud`. A trailing `/v1` is dropped, since every
operation path already carries it:

```sh
export UKC_METRO=https://api.staging.example.internal
```

A named endpoint is the only endpoint there is: no metro discovery is
attempted and no hostnames are invented, whatever the scope says. Point the
control plane at a matching deployment with `control_plane_url:`:

```ruby
ukc = Unikraft::Cloud.new(
  token: ENV["UKC_TOKEN"],
  metro: "https://api.staging.example.internal",
  control_plane_url: "https://controlplane.staging.example.internal"
)
```

## Runtime support

The SDK needs Ruby 3.3 or later (CI covers 3.3, 3.4 and 4.0) and has no
runtime dependencies: it uses `net/http`, `json` and `uri` from the standard
library.

To customise the transport (a different HTTP stack, instrumentation, or a fake
in tests), pass `transport:`, a callable that receives the transport keywords
(`base_url:`, `token:`, `headers:`, `timeout:`, `proxy_from_env:`,
`user_agent:`) and returns an object with `request`, `bytes` and `stream`, as
`Unikraft::Cloud::Core::ApiClient` has:

```ruby
ukc = Unikraft::Cloud.new(
  transport: ->(**config) { Unikraft::Cloud::Core::ApiClient.new(**config) }
)
```

## Debugging with a proxy (MITM)

The client honours the standard proxy environment variables through
`Net::HTTP`, so you can route traffic through a man-in-the-middle proxy such
as [mitmproxy](https://mitmproxy.org), Charles, or Proxyman without any code
change:

```sh
export https_proxy=http://127.0.0.1:8080
export SSL_CERT_FILE=~/.mitmproxy/mitmproxy-ca-cert.pem # trust the proxy CA
ruby your_script.rb
```

`http_proxy`, `https_proxy` and `no_proxy` are recognised, in lower- or
upper-case. `SSL_CERT_FILE` replaces OpenSSL's default trust store for the
process, which is what lets it trust the proxy's certificate; unset it when
you are done. Opt out of the proxy variables per client with
`Unikraft::Cloud.new(proxy_from_env: false)`.

## Contributing

The plumbing layer is generated; see [CONTRIBUTING.md](./CONTRIBUTING.md) for
how to regenerate it and work on the SDK.

## License

BSD-3-Clause. See [LICENSE.md](./LICENSE.md).

[ukc]: https://unikraft.com
[openapi]: https://github.com/unikraft-cloud/openapi
[dashboard]: https://console.unikraft.cloud
