# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# The base every idiomatic ("porcelain") resource client is built on. It owns
# the metro scope, the plumbing client the operations go through, and the two
# hard problems of a metro-scoped API: finding which metro holds a named
# resource, and grouping a bulk operation by metro.

require_relative "errors"
require_relative "fanout"
require_relative "handle"
require_relative "handle_set"
require_relative "metro"
require_relative "pagination"
require_relative "ref"
require_relative "response"

module Unikraft
  module Cloud
    module Core
      # A porcelain client bound to a metro scope. It holds, rather than
      # inherits from, its plumbing client ({#api}).
      class Scoped
        # The per-call options every porcelain method takes besides its own:
        # `metros:` overrides the scope, `base_url:` names one endpoint, and
        # `headers:` and `timeout:` go to the transport.
        OPTIONS = %i[metros base_url headers timeout].freeze

        # @return [Object] the raw ("plumbing") client of this resource: every
        #   operation of the specification, returning the envelope untouched.
        #   Calls go to the scope's metro unless given `base_url:`.
        attr_reader :api
        # @return [:all, Array<String>] the metros this client covers
        attr_reader :scope

        # @api private
        def initialize(session, scope, transport)
          @session = session
          @scope = scope
          @api = self.class::API_CLASS.new(transport)
        end

        # The keywords of one plumbing call to an endpoint.
        #
        # @api private
        # @param target [Endpoint, Location]
        # @param call [Hash] `headers:`, `timeout:`; any other {OPTIONS} key
        #   is ignored, and an unknown one raises
        def call_options(target, call)
          { base_url: target.base_url, **check_options!(call).slice(:headers, :timeout) }
        end

        def inspect = "#<#{self.class.name} scope=#{@scope.inspect}>"

        private

        # The endpoints a call covers, honouring `metros:` or `base_url:`.
        def endpoints(opts)
          return [explicit(opts[:base_url])] if opts[:base_url]

          @session.resolve(opts.key?(:metros) ? Metro.scope(opts[:metros]) : @scope)
        end

        # The single endpoint of an operation that must pick one metro.
        def one_endpoint(operation, opts)
          return explicit(opts[:base_url]) if opts[:base_url]

          @session.resolve_one(opts.key?(:metros) ? Metro.scope(opts[:metros]) : @scope, operation)
        end

        def explicit(url)
          url = Metro.base_url(url)
          Endpoint.new(metro: url, base_url: url)
        end

        def check_options!(opts)
          unknown = opts.keys - OPTIONS
          raise ArgumentError, "unknown keyword(s): #{unknown.join(", ")}" unless unknown.empty?

          opts
        end
      end

      # The collection operations every resource shares: create, get, where,
      # list (and Enumerable), delete, update and edit.
      class Resource < Scoped
        include Enumerable

        # What a concrete resource is called and which operations serve it.
        Spec = Data.define(:noun, :key, :list, :create, :delete, :update)

        # @api private
        # @return [Spec]
        def spec = self.class::SPEC

        # Create a resource in one metro and return a handle on it. Creating
        # never fans out: it uses the scope's metro, or the default metro
        # when the scope is wider. `metro:` picks the metro, like
        # `metros: [metro]`, and never reaches the body.
        #
        # @param attributes [Hash, nil] the request body; keywords are
        #   merged over it
        # @return [Handle]
        def create(attributes = nil, **kwargs)
          body, opts = create_args(attributes, kwargs)
          endpoint = one_endpoint("Creating #{article} #{spec.noun}", opts)
          res = api.public_send(spec.create, body:, **call_options(endpoint, opts))
          value = Response.first(res, spec.key, spec.noun).with_metro(endpoint.metro)
          ref = Ref.new(uuid: value[:uuid], name: value[:uuid] ? nil : value[:name],
                        metro: endpoint.metro)
          location = Location.new(ref:, metro: endpoint.metro, base_url: endpoint.base_url)
          self.class::HANDLE.new(self, ref, opts, located: Located.new(location:, value:),
                                                  partial: true)
        end

        # A handle on one resource. Nothing is sent until it is used; then
        # the resource is located (one concurrent read per metro, unless the
        # ref or the scope already names the metro) and read once.
        #
        # @example
        #   ukc.instances.get(name: "web")
        #   ukc.instances.get(uuid: "550e8400-e29b-41d4-a716-446655440000")
        #   ukc.instances.get(name: "web", metro: :fra)
        #   ukc.instances.get({ name: "web" }, metros: %i[fra dal])
        # @param ref [Hash, Ref, nil] or pass `name:`/`uuid:`/`metro:`
        # @return [Handle]
        # @raise [ArgumentError] for both or neither of name and uuid
        def get(ref = nil, **kwargs)
          ref, opts = split(ref, kwargs)
          self.class::HANDLE.new(self, ref, opts) { |call = {}| locate(ref, opts.merge(call)) }
        end

        # Every resource matching a ref, one per metro holding it: the
        # deliberate plural of {#get}.
        #
        # @example
        #   ukc.instances.where(name: "web").suspend
        # @return [HandleSet]
        def where(ref = nil, **kwargs)
          ref, opts = split(ref, kwargs)
          self.class::SET.new(spec.noun) do |call = {}|
            located = opts.merge(call)
            locate_all(ref, located).map do |hit|
              self.class::HANDLE.new(self, hit.location.ref, located, located: hit)
            end
          end
        end

        # Every resource in scope, following each metro's pagination and
        # interleaving the metros as their pages arrive. Each result is
        # tagged with its `metro`. If some metros fail, the healthy ones are
        # drained first, then a {MetroFanoutError} is raised.
        #
        # @param details [Boolean, nil] full resources rather than refs
        # @param page_size [Integer, nil] the page size while paginating
        # @param filters [Hash] e.g. `tags:` where the list operation takes
        #   it (instances, volumes), plus the call options
        # @return [Enumerator, self] an Enumerator without a block
        def list(details: nil, page_size: nil, **filters, &block)
          opts = check_options!(takes_tags? ? filters.except(:tags) : filters)
          query = { details:, tags: filters[:tags] }.compact
          enum = Enumerator.new do |out|
            Fanout.merge(endpoints(opts), out) do |endpoint, emit|
              fetch = lambda do |count, from|
                res = api.public_send(spec.list, count:, from:, **query,
                                                 **call_options(endpoint, opts))
                Response.list(res, spec.key).map { |item| item.with_metro(endpoint.metro) }
              end
              Pagination.each(fetch:, page_size:, &emit)
            end
          end
          return enum unless block

          enum.each(&block)
          self
        end

        # Enumerable over every resource in scope, with details.
        #
        # @yieldparam resource [Model]
        def each(&)
          return enum_for(:each) unless block_given?

          list(details: true, &)
        end

        # Delete one or more resources, in whichever metros hold them. Under
        # a wide scope a name deletes every match in scope; qualify the ref
        # or narrow the scope to delete one.
        #
        # @example
        #   ukc.instances.delete(name: "web", metro: :fra)
        #   ukc.instances.delete([{ name: "a" }, { uuid: "..." }])
        # @param refs [Hash, Ref, Array, nil] or pass one ref as keywords
        # @return [Array<Model>] what each metro reported, tagged
        def delete(refs = nil, **kwargs) = bulk(spec.delete, refs, kwargs)

        # Change one resource. Shorthand for `get(ref).update(...)`: the ref
        # keys (and `metros:`/`base_url:`) locate it, `headers:` and
        # `timeout:` go to the call, the rest is the patch.
        #
        # @example
        #   ukc.instances.update(name: "web", memory_mb: 512)
        #   ukc.instances.update({ name: "web" }, [{ prop: "vcpus", op: "set", value: 2 }])
        # @return [Handle]
        def update(ref = nil, changes = nil, **kwargs)
          handle, rest = on(ref, kwargs)
          handle.update(changes, **rest)
        end

        # Stage changes to one resource. Shorthand for `get(ref).edit`.
        #
        # @return [Patch::Editor, Handle]
        def edit(ref = nil, **kwargs, &)
          handle, call = on(ref, kwargs)
          handle.edit(**call, &)
        end

        # Read one resource where it was located.
        #
        # @api private
        # @return [Model]
        def fetch(location, **call)
          res = api.public_send(spec.list, **location.ref.query, details: true,
                                                                 **call_options(location, call))
          Response.first(res, spec.key, "#{spec.noun} #{location.ref}").with_metro(location.metro)
        end

        private

        def article = spec.noun.match?(/\A[aeiou]/) ? "an" : "a"

        # Whether the list operation filters by `tags:`.
        def takes_tags? = api.method(spec.list).parameters.include?(%i[key tags])

        # The body and call options of a create: keywords merge over the
        # positional attributes, and `metro:` routes rather than sends.
        def create_args(attributes, kwargs)
          opts = kwargs.slice(*OPTIONS)
          body = (attributes || {}).merge(kwargs.except(*OPTIONS))
          if (metro = body.delete(:metro))
            raise ArgumentError, "pass `metro:` or `metros:`, not both" if opts.key?(:metros)

            opts[:metros] = metro
          end
          [body, opts]
        end

        # A ref from a positional Hash or keywords, and the call options.
        def split(ref, kwargs)
          ref_kw = kwargs.slice(*Ref.members)
          opts = check_options!(kwargs.except(*Ref.members))
          if ref && ref_kw.any?
            raise ArgumentError,
                  "pass the ref positionally or as keywords, not both"
          end

          [ref ? Ref.coerce(ref) : Ref.new(**ref_kw), opts]
        end

        # A handle from the locating keywords, and the keywords left for the
        # operation, for the shorthand forms. `headers:` and `timeout:` go to
        # both: the lookup needs the same credentials as the operation.
        def on(ref, kwargs)
          locating = Ref.members + %i[metros base_url]
          [get(ref, **kwargs.slice(*locating, :headers, :timeout)), kwargs.except(*locating)]
        end

        def bulk(operation, refs, kwargs)
          check_options!(kwargs) if refs # positional refs leave only options
          opts = kwargs.slice(*OPTIONS)
          refs = Ref.list(refs || Ref.coerce(kwargs.except(*OPTIONS)))
          groups = group_by_metro(refs, opts)
          run = lambda do |endpoint|
            body = groups[endpoint].map(&:wire)
            res = api.public_send(operation, body:, **call_options(endpoint, opts))
            Response.list(res, spec.key).map { |item| item.with_metro(endpoint.metro) }
          end
          return run.call(groups.keys.first) if groups.size == 1

          Fanout.all(groups.keys, flat: true, &run)
        end

        # The endpoints to search for one ref. A ref that names its metro
        # needs no search and no discovery.
        def endpoints_for(ref, opts)
          return [@session.endpoint_for(ref.metro)] if ref.metro && !opts[:base_url]

          endpoints(opts)
        end

        # Find which metro holds one resource. Free when the ref or the scope
        # already says; otherwise every metro is asked concurrently, and the
        # resource found travels back so it is not read twice. A name in
        # several metros raises rather than guessing, since the caller may be
        # about to mutate it. A uuid should be unique, but if several metros
        # report it, that is just as ambiguous.
        def locate(ref, opts)
          found = locate_all(ref, opts)
          return found.first if found.size == 1

          metros = found.map { |hit| hit.location.metro }
          id = ref.uuid ? "uuid: #{ref.uuid.inspect}" : "name: #{ref.name.inspect}"
          raise AmbiguousRefError.new(
            "#{spec.noun} #{ref} exists in #{found.size} metros (#{metros.join(", ")}). Say " \
            "which one with `get(#{id}, metro: :#{metros.first})`, or act on all of them " \
            "with `where(#{id})`.",
            matches: found.map(&:value)
          )
        end

        # Locate every metro holding a match: the same name in five metros
        # is five results, not an error. One endpoint is taken on trust,
        # lazily, rather than spending a request to confirm it.
        def locate_all(ref, opts)
          endpoints = endpoints_for(ref, opts)
          if endpoints.size == 1
            return [Located.new(location: location_at(endpoints.first, ref),
                                value: nil)]
          end

          search(ref, endpoints, opts).map do |endpoint, value|
            Located.new(location: location_at(endpoint, ref), value:)
          end
        end

        def location_at(endpoint, ref)
          Location.new(ref: ref.with(metro: endpoint.metro), metro: endpoint.metro,
                       base_url: endpoint.base_url)
        end

        # Ask every endpoint for the ref concurrently. Absent is not a
        # failure, but absent everywhere is. Any metro that could not answer
        # fails the search too, even with matches elsewhere: it might hold
        # another match, and the caller may be about to mutate it.
        def search(ref, endpoints, opts)
          outcomes = Fanout.settled(endpoints) { |endpoint| lookup(endpoint, ref, opts) }
          hits = outcomes.select { |o| o.ok? && o.value }
          found = hits.map { |o| [o.item, o.value.with_metro(o.item.metro)] }
          failures = outcomes.reject(&:ok?).map { |o| { metro: o.item.metro, error: o.error } }
          return found if failures.empty? && found.any?

          not_found(ref, endpoints.map(&:metro).join(", "), failures, found)
        end

        def not_found(ref, searched, failures, found)
          unreachable = failures.map { |f| f[:metro] }.join(", ")
          if found.any?
            raise MetroFanoutError.new(
              "#{spec.noun} #{ref} was found in #{found.map { |e, _| e.metro }.join(", ")}, but " \
              "#{failures.size} metros could not be reached and might hold it too: #{unreachable}.",
              failures:, results: found.map(&:last)
            )
          end
          if failures.any?
            raise MetroFanoutError.new(
              "#{spec.noun} #{ref} was not found in #{searched}, and #{failures.size} of those " \
              "metros could not be reached: #{unreachable}.",
              failures:
            )
          end
          raise Error.new("#{spec.noun} #{ref} not found in #{searched}", kind: :http, status: 404)
        end

        # Look for one resource in one metro; nil when it is not there.
        def lookup(endpoint, ref, opts)
          Response.absent do
            res = api.public_send(spec.list, **ref.query, details: true,
                                                          **call_options(endpoint, opts))
            Response.first(res, spec.key, spec.noun)
          end
        end

        # Group refs by the metro holding them, so a bulk operation is one
        # call per metro. Free when the scope is one metro and no ref names
        # its own; otherwise refs are located concurrently, and a name
        # matching in several metros counts in each. Refs that all name
        # their metro skip resolving the scope, and so discovery.
        def group_by_metro(refs, opts)
          if refs.none?(&:metro)
            endpoints = endpoints(opts)
            return { endpoints.first => refs } if endpoints.size == 1
          end

          outcomes = Fanout.settled(refs) { |ref| locate_all(ref, opts) }
          failed = outcomes.find { |o| !o.ok? }
          raise failed.error if failed

          outcomes.flat_map(&:value).each_with_object({}) do |hit, groups|
            loc = hit.location
            (groups[Endpoint.new(metro: loc.metro, base_url: loc.base_url)] ||= []) << loc.ref
          end
        end
      end
    end
  end
end
