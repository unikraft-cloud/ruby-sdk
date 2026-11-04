# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# Changing an instance's properties. Run with:
#   UKC_TOKEN=... ruby -Ilib examples/update.rb

require "unikraft/cloud"

ukc = Unikraft::Cloud.new
web = ukc.metro(:fra).instances.get(name: "web")

begin
  # Keyword arguments: a value sets the property, nil removes it, and
  # anything omitted is left alone. One request, whatever you pass.
  updated = web.update(memory_mb: 512, vcpus: 2, env: { LOG_LEVEL: "debug" }, autokill: nil)
  puts "#{updated.name} in #{updated.metro}: #{updated.status}"

  # When `set` is not what you mean (merge into a property, or remove single
  # members), stage the operations and apply them together at the block's end.
  web.edit do |e|
    e.set(hostname: "web-1")
    e.add(env: { FEATURE_X: "1" }, tags: ["prod"])
    e.remove(env: ["LOG_LEVEL"], tags: ["staging"])
  end

  # The chained form: `apply` returns a handle, so the chain continues.
  web.edit.set(memory_mb: 1024).apply.wait(state: :running)

  # The raw triples remain available for anything keywords do not cover.
  ukc.metro(:fra).instances.update({ name: "web" }, [{ prop: "memory_mb", op: "set", value: 256 }])
rescue Unikraft::Cloud::Error => e
  warn "API error (#{e.status || "?"}): #{e.message}"
  exit 1
ensure
  ukc.close
end
