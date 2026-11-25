# frozen_string_literal: true

require_relative "lib/unikraft/cloud/version"

Gem::Specification.new do |spec|
  spec.name = "unikraft-cloud"
  spec.version = Unikraft::Cloud::VERSION
  spec.authors = ["Unikraft GmbH"]
  spec.summary = "The official Ruby SDK for Unikraft Cloud."
  spec.description = "Client for the Unikraft Cloud platform and " \
                     "control-plane APIs."
  spec.homepage = "https://unikraft.com"
  spec.license = "BSD-3-Clause"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/unikraft-cloud/ruby-sdk",
    "rubygems_mfa_required" => "true"
  }

  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, &:read)
                 .split("\x0")
                 .select { |f| f.start_with?("lib/", "README", "LICENSE") }
  spec.require_paths = ["lib"]

  # The generated plumbing of the sandbox plugin, which `sandboxes` wraps.
  spec.add_dependency "unikraft-cloud-plugin-sandbox-api", "~> 1.0"
end
