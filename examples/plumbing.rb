# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# Using the low-level "plumbing" API directly. Every method returns the raw
# response envelope exactly as the OpenAPI specification describes it, and
# each client talks to exactly one metro. Reach for this when you need a field
# or an operation the idiomatic layer does not expose yet.
#
#   UKC_TOKEN=... ruby -Ilib examples/plumbing.rb

require "unikraft/cloud"

token = ENV.fetch("UKC_TOKEN")

# Every platform resource behind one transport...
platform = Unikraft::Cloud::API::Platform.new(base_url: "https://api.fra.unikraft.cloud", token:)

# ...and the control plane, which is global rather than metro-scoped.
controlplane = Unikraft::Cloud::API::ControlPlane.new(
  base_url: Unikraft::Cloud::CONTROLPLANE_BASE_URL, token:
)

res = platform.instances.get_instances(count: 10, details: true)
puts "status: #{res.status}, op_time_us: #{res[:op_time_us]}"
res.data&.instances&.each { |inst| puts "- #{inst.name}" }

quotas = platform.users.get_user
p quotas.data&.quotas

# Ask the control plane where the metros are, then aim a single call at one of
# them with a per-call `base_url:`: the fan-out the idiomatic layer does for you.
controlplane.metros.list_metros.data&.metros&.each do |metro|
  # Endpoints may end in /v1, which the operation's path already carries.
  base_url = Unikraft::Cloud::Core::Metro.base_url(metro.endpoint)
  there = platform.instances.get_instances(count: 1, base_url:)
  puts "#{metro.iata_code}: #{there.data&.instances&.size || 0} instance(s)"
end
