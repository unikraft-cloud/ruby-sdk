# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# Idiomatic quickstart. Run with:
#   UKC_TOKEN=... ruby -Ilib examples/quickstart.rb

require "unikraft/cloud"

# The token comes from UKC_TOKEN; `open` closes the client after the block.
Unikraft::Cloud.open do |ukc|
  # Creating a resource happens in one metro. Name it, and every operation on
  # that scope needs no lookup.
  fra = ukc.metro(:fra)

  instance = fra.instances.create(
    image: "nginx:latest",
    memory_mb: 256,
    autostart: true,
    service_group: {
      services: [{ port: 443, handlers: %w[tls http], destination_port: 80 }]
    }
  )
  puts "created #{instance.name} (#{instance.uuid}) in #{instance.metro}"

  # Mutations run at once and return a handle, so calls chain: wait for the
  # instance to come up, then read the tail of its console log.
  logs = instance.wait(state: :running, within: 30).logs(offset: -4096)
  puts logs.output.to_s.unpack1("m")

  # Without a metro, the client is account-wide: every metro is asked in
  # parallel and the pages are merged as they arrive.
  ukc.instances.list(details: true) do |inst|
    puts "- #{inst.metro}/#{inst.name}: #{inst.state}"
  end

  # A handle resolves to the metro that actually holds the instance, so the
  # suspend is sent there and nowhere else.
  ukc.instances.get(name: instance.name).suspend

  # Bulk operations take one ref or an Array of them.
  fra.instances.delete([{ uuid: instance.uuid }])
rescue Unikraft::Cloud::Error => e
  warn "API error (#{e.status || "?"}): #{e.message}"
  exit 1
end
