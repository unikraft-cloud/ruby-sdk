# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require "bundler/gem_tasks"
require "minitest/test_task"
require "rubocop/rake_task"
require "rbconfig"
require "tmpdir"

Minitest::TestTask.create(:test) do |t|
  t.test_globs = ["test/unit/**/*_test.rb"]
end

namespace :test do
  Minitest::TestTask.create(:e2e_run) do |t|
    t.test_globs = ["test/e2e/**/*_test.rb"]
  end

  desc "Run the end-to-end tests against a live account (needs UKC_TOKEN)"
  task :e2e do
    abort "test:e2e needs UKC_TOKEN in the environment" if ENV.fetch("UKC_TOKEN", "").empty?
    Rake::Task["test:e2e_run"].invoke
  end
end

RuboCop::RakeTask.new(:lint)

desc "Install the built gem into a temporary GEM_HOME and require it"
task check_package: :build do
  gem = Dir["pkg/unikraft-cloud-*.gem"].max_by { |f| File.mtime(f) }
  Dir.mktmpdir do |home|
    env = { "GEM_HOME" => home, "GEM_PATH" => home }
    Bundler.with_unbundled_env do
      sh env, "gem", "install", "--local", "--no-document", gem
      sh env, RbConfig.ruby, "-e",
         'require "unikraft/cloud"; puts "unikraft-cloud " + Unikraft::Cloud::VERSION'
    end
  end
end

task default: %i[lint test]
