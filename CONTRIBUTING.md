# Contributing to `unikraft-cloud`

Thanks for your interest in improving the Unikraft Cloud Ruby SDK!

## Architecture

The SDK is deliberately split into two layers:

```
lib/
  unikraft/
    cloud.rb          # entry point: Unikraft::Cloud.new and the public requires
    cloud/
      version.rb      # VERSION = "0.0.0" placeholder, stamped by the release
      api/            # the "plumbing" layer: raw, spec-shaped
        platform/     #   GENERATED (*.gen.rb): one class per tag + models
        controlplane/ #   GENERATED (*.gen.rb)
        *.rb          #   hand-written API::Platform / API::ControlPlane containers
      core/           # hand-written shared machinery: transport, errors,
                      #   metros, fan-out, pagination, models
      resources/      # the "porcelain" layer: hand-written idiomatic clients
templates/            # Go templates consumed by openapi-gen to produce *.gen.rb
test/                 # minitest suites
```

Everything matching `lib/unikraft/cloud/api/**/*.gen.rb` is generated from the
[OpenAPI specification][openapi] and **must not be edited by hand**: changes
would be lost on the next regeneration. To change generated output, edit the
templates in `templates/` (or the generator itself, see below). The
hand-written container files beside the generated ones are safe to edit.

The two layers are kept apart deliberately:

- **Plumbing** (`lib/unikraft/cloud/api/**`) mirrors the specification:
  `Unikraft::Cloud::API::Platform` and `Unikraft::Cloud::API::ControlPlane`
  hold one class per tag (`API::Platform::InstancesApi`, ...), whose methods
  are the snake_cased `operationId`s (`get_instances`), take keyword
  arguments, and return the response envelope untouched. One plumbing client
  talks to one metro.
- **Porcelain** (`lib/unikraft/cloud/resources/**`) **holds** a plumbing
  client rather than inheriting from one, so its surface stays small and
  deliberate: short verbs, unwrapped results, auto-pagination, metro fan-out,
  chainable handles.

Because the layers are composed rather than inherited, a newly generated
operation does **not** appear on the idiomatic client automatically. It is
reachable through the plumbing client until someone wraps it. Wrap only where
it improves the developer experience.

When adding a porcelain method, keep the metro rules of the resource base
class in `lib/unikraft/cloud/core/`. Reads fan out across the scope and tag
results with `metro` (`Model#with_metro`). A name only identifies a resource
*within* a metro, so a ref may match in several: an operation that acts on one
resource raises `Unikraft::Cloud::AmbiguousRefError`, with the matches
attached, rather than guessing; an operation that acts on all of them works
on every match; creation picks exactly one endpoint. A fan-out that fails in
some metros raises `Unikraft::Cloud::MetroFanoutError` carrying both the
failures and the partial results. `metro` says where to send a request and
must never reach the wire inside a body.

### The transport contract

The generated plugin gems, `unikraft-cloud-plugin-<name>-api` (required as
`unikraft/cloud/plugin/<name>/api`, namespace
`Unikraft::Cloud::Plugin::<Name>::API`), are produced by the Ruby generator
in [plugin-sdk] at `ruby/tools/sdkgen`. They take a transport in their
constructor: any object that responds to

- `request(method:, path:, query: nil, body: nil, headers: nil, **options)`,
  returning the parsed JSON,
- `bytes(...)`, returning the body as a binary `String`, and
- `stream(...) { |chunk| ... }`, yielding the body in chunks.

The contract is duck-typed, so a plugin gem needs no dependency on the SDK.
The porcelain hands each plugin client a `Unikraft::Cloud::Core::ApiClient`,
which satisfies it, and the test suite checks that against the published
plugin gem. Two rules follow:

- Widening is safe. A new optional keyword or a wider accepted input is a
  `fix:` or a `feat:`.
- A rename, a new required keyword, or a changed return type is a `feat!:`.
  It needs the same change in the plugin-sdk generator and a republish of
  every plugin gem in the same cycle.

`ApiClient` must not rely on a keyword the contract does not declare. Ruby
checks none of this ahead of time, so only the tests can see that drift.

## Prerequisites

- Ruby 3.3+ (CI covers 3.3, 3.4 and 4.0)
- Go (only needed to regenerate `lib/unikraft/cloud/api`)

```sh
bundle install
```

## Common tasks

```sh
make generate                 # regenerate lib/unikraft/cloud/api (default channel: prod-staging)
make build                    # build the gem into pkg/
make lint                     # rubocop
make test                     # minitest unit tests
make clean                    # remove build output

bundle exec rake test         # unit tests
bundle exec rake test:e2e     # end-to-end tests against the live API (needs UKC_TOKEN)
bundle exec rake lint         # rubocop
bundle exec rake build        # gem build into pkg/
bundle exec rake check_package # install the built gem into a temporary GEM_HOME and require it
```

## Regenerating the client

```sh
make generate                     # prod-staging channel
make generate CHANNEL=prod-stable # stable channel
```

`make generate` runs [`openapi-gen`][openapi-gen] against the channel's
`platform.json` and `controlplane.json`, writing Ruby into
`lib/unikraft/cloud/api/platform` and `lib/unikraft/cloud/api/controlplane`
respectively. The spec-independent HTTP transport is the hand-written
`Unikraft::Cloud::Core::ApiClient`, shared by both.

> [!NOTE]
> Some read operations still model their filters as a request body on a
> `GET` in the spec. The transport refuses to attach a body to `GET` or
> `HEAD`, so the generated methods for those operations send only their query
> parameters; the spec exposes the same filters as repeatable query
> parameters. If a new `GET` operation ever ships body-only filters with no
> query equivalent, it needs a spec fix rather than a template workaround.

To use a locally built generator, point `OPENAPI_GEN` at the binary:

```sh
(cd ../x/tools/openapi-gen && go build -o /tmp/openapi-gen .)
make generate OPENAPI_GEN=/tmp/openapi-gen
```

Commit the regenerated `lib/unikraft/cloud/api` together with the change that
motivated it. The `sync` workflow does the same from CI and opens a pull
request touching only that directory.

## Release channels

There are two channels, mirroring the OpenAPI spec branches:

| Channel        | OpenAPI branch | RubyGems release | Version shape      |
| -------------- | -------------- | ---------------- | ------------------ |
| `prod-stable`  | `prod-stable`  | stable           | `0.2.0`            |
| `prod-staging` | `prod-staging` | prerelease       | `0.2.1.pre.next.3` |

Pushing to a channel branch publishes the gem (see
`.github/workflows/release.yaml`). RubyGems has no dist-tags, so the version
alone tells the channels apart. Any letter in a RubyGems version makes it a
prerelease, which sorts below the matching release, so
`gem install unikraft-cloud` gets the newest stable release and

```sh
gem install unikraft-cloud --pre
```

gets the newest prerelease. Bundler resolves a prerelease only when the
Gemfile requirement names one.

The prerelease spelling is the one RubyGems itself derives from the semver
string svu prints: `Gem::Version.new("0.2.1-next.3")` is `0.2.1.pre.next.3`.
It sorts above `0.2.0` and below `0.2.1`, and the counter compares
numerically, so `next.10` sorts above `next.9`.

Publishing uses [RubyGems trusted publishing][rubygems-tp]: the workflow
exchanges its GitHub Actions OIDC token for a short-lived API key, so there
is no RubyGems secret to rotate. The trusted publisher is registered on
rubygems.org against this repository and the `release.yaml` workflow file:
renaming or moving that file breaks publishing until the RubyGems-side
configuration is updated to match. RubyGems accepts a *pending* trusted
publisher for a gem that does not exist yet, so the very first release needs
no manual `gem push`: register the pending publisher for `unikraft-cloud`,
then push to a channel branch.

[rubygems-tp]: https://guides.rubygems.org/trusted-publishing/

### Versioning

`lib/unikraft/cloud/version.rb` holds the placeholder `0.0.0` on every
branch. Leave it there. The release workflow computes the real number with
[svu][svu] and writes it in the runner, seconds before building the gem.

That makes the commit message the input to the version: a `fix:` gives a
patch, a `feat:` a minor, and a `!` a minor for as long as the major is 0. The
largest bump in the range wins, so two fixes and a feature give one minor
bump. A range of only `chore:` commits publishes nothing from `prod-stable`.

Git tags are the record of what shipped. Only `prod-stable` pushes them, after
the tests pass.

### Promote `prod-staging` to `prod-stable`

`prod-stable` receives code only through a promotion pull request, which
carries no commit of its own:

```sh
git fetch origin
git switch -c promote/<date> origin/prod-stable
git merge origin/prod-staging
git push -u origin promote/<date>
gh pr create --base prod-stable --fill
```

Cut the branch from `prod-stable`. A branch cut from `prod-staging` makes the
pull request show every commit that stable has not seen, which is
unreviewable.

Two outcomes look like failures and are not. A promotion carrying nothing
bumpable publishes nothing. And between a release and the next push to
`prod-staging`, the newest prerelease sits one notch below the newest stable
release, because both point at the same code.

## Code style

- Formatting and linting are enforced by [RuboCop](https://rubocop.org)
  (`bundle exec rake lint`). Run `bundle exec rubocop -a` to fix.
- Keep runtime dependencies at zero: rely on the standard library
  (`net/http`, `json`, `uri`, ...). The one exception is the generated plugin
  plumbing gems (`unikraft-cloud-plugin-<name>-api`), which the porcelain
  wraps.
- Add a test in `test/` for new idiomatic behaviour.

## Commit messages

This repository uses [Conventional Commits][cc]; pull requests targeting
`prod-staging` are validated in CI. Sign off every commit (`git commit -s`).

[openapi]: https://github.com/unikraft-cloud/openapi
[plugin-sdk]: https://github.com/unikraft-cloud/plugin-sdk
[openapi-gen]: https://github.com/unikraft-cloud/x/tree/prod-staging/tools/openapi-gen
[cc]: https://www.conventionalcommits.org
[svu]: https://github.com/caarlos0/svu
