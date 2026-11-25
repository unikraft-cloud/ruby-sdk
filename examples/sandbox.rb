# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# Sandboxes: a virtual machine that runs whatever command you hand it. Run
# with:
#   UKC_TOKEN=... ruby -Ilib examples/sandbox.rb

require "unikraft/cloud"

# The hot path: credentials and image from the environment, and the sandbox
# deleted when the block returns.
def hot_path
  Unikraft::Cloud::Sandbox.create do |sb|
    puts sb.run("echo hello").stdout # hello
  end
end

def configured
  sb = Unikraft::Cloud::Sandbox.create(
    image: "debian-slim:latest",
    memory_mb: 1024,
    env: { "LOG_LEVEL" => "debug" },
    rom: "plugins/sandbox:latest", # your own plugin ROM
    token: ENV.fetch("UKC_TOKEN"),
    metro: :fra,
    boot_within: 60,
    ready: { within: 30 }
  )

  # The instance underneath stays reachable, so its whole surface works.
  inst = sb.instance
  puts "#{inst.name} in #{sb.metro}: #{inst.state}, #{inst.memory_mb} MiB"

  # A command takes a working directory and its own environment.
  build = sb.run("ls -la && env", cwd: "/tmp", env: { "CI" => "1" })
  puts "exit #{build.exitcode}: #{build.stdout}#{build.stderr}"
  files_and_stdin(sb)

  # The UUID and the metro are all a later process needs to attach again.
  again = Unikraft::Cloud::Sandbox.connect(uuid: sb.uuid, metro: sb.metro)
  puts "reconnected to #{again.uuid}"

  # Without a block, delete it yourself.
  sb.delete
end

def files_and_stdin(sandbox)
  # Files go in and come back out.
  sandbox.files.mkdir("/work/input")
  sandbox.files.write("/work/input/a.txt", "hello\n")
  sandbox.files.upload("/work/input", "data.csv", "id,name\n1,fra\n")
  puts sandbox.files.read("/work/input/a.txt")

  # `spawn` does not wait, so the command stays under your control: write to
  # its standard input, wait for it, then read its logs. `signal(:TERM)`
  # ends one that does not stop on its own.
  cat = sandbox.spawn("cat", cwd: "/work")
  cat.write("first line\n").write("last line\n").close_write
  puts cat.wait(within: 10).logs.stdout
  cat.delete
end

def through_a_client
  # A client you already have opens the same door, and spends no second token.
  Unikraft::Cloud.open do |ukc|
    fra = ukc.metro(:fra)
    fra.sandboxes.create(memory_mb: 512) { |sb| puts sb.run("uname", "-a").stdout }

    # Every sandbox in the metro: the instance list, filtered by plugin.
    fra.sandboxes.each { |sb| puts "- #{sb.uuid}" }
  end
end

begin
  hot_path
  configured
  through_a_client
rescue Unikraft::Cloud::Error => e
  warn "API error (#{e.status || "?"}): #{e.message}"
  exit 1
end
