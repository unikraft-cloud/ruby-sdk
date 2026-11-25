# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# One command inside a sandbox, addressed by the UUID the plugin assigned it.

require_relative "../../core/base64"
require_relative "../../core/errors"
require_relative "../../core/response"

module Unikraft
  module Cloud
    class Sandbox
      # A command's output: both streams decoded as UTF-8, and the total size
      # of each, which a {Command#read} range can then address.
      Logs = Data.define(:stdout, :stderr, :stdout_available, :stderr_available)

      # A command inside a sandbox, from {Sandbox#spawn}, {Sandbox#command} or
      # {Sandbox#commands}. Each method is exactly one request, so a caller
      # can see what a wait costs. Standard input reads like an IO opened for
      # writing: {#write} and {#close_write}.
      #
      # @example
      #   cat = sb.spawn("cat")
      #   cat.write("first line\n").close_write
      #   cat.wait(within: 10).logs.stdout  # => "first line\n"
      #   sb.spawn("sleep 30").signal(:TERM)
      class Command
        # @return [String] the command's UUID, assigned by the plugin
        attr_reader :uuid
        # @return [Sandbox] the sandbox the command runs in
        attr_reader :sandbox

        # @api private
        def initialize(sandbox, uuid)
          @sandbox = sandbox
          @uuid = uuid
        end

        # The command line, working directory, environment and `exitcode`,
        # which is nil while the command runs. The only operation that
        # reports the exit code.
        #
        # @param call [Hash] `headers:`, `timeout:`
        # @return [Plugin::Sandbox::API::Models::GetCommandData]
        def info(**call) = unwrap(api.get_command_by_uuid(uuid:, **call))

        # Block until the command exits, or until `within` seconds pass. A
        # wait that runs out is not an error: the command keeps running, and
        # {#info} says whether it finished.
        #
        # @example
        #   cmd.wait                 # however long it takes
        #   cmd.wait(within: 5)      # then return regardless
        # @param within [Numeric, nil] seconds the plugin waits; decimals are
        #   accepted. The plugin holds the request open meanwhile, so the
        #   read timeout is stretched to cover it (or lifted without
        #   `within`), unless `timeout:` sets it.
        # @param call [Hash] `headers:`, `timeout:` (the HTTP timeout)
        # @return [self]
        def wait(within: nil, **call)
          # The plugin holds the request open for the wait.
          call = { timeout: within && (within + 10) }.merge(call)
          if within.nil?
            unwrap(api.wait_for_command(uuid:, **call))
            return self
          end
          begin
            unwrap(api.wait_for_command_with_timeout(uuid:, body: { timeout_s: within }, **call))
          rescue Error => e
            # 408 is the plugin saying the timeout elapsed, which is what was
            # asked for; every other status is still a failure.
            raise unless e.kind == :http && e.status == 408
          end
          self
        end

        # Both output streams, decoded.
        #
        # @return [Logs]
        def logs(**call)
          data = unwrap(api.get_command_logs(uuid:, **call))
          Logs.new(stdout: Core::Base64.decode_text(data&.stdout),
                   stderr: Core::Base64.decode_text(data&.stderr),
                   stdout_available: data&.stdout_available,
                   stderr_available: data&.stderr_available)
        end

        # One output stream as bytes, optionally a byte range of it. The
        # range goes in a `Range` header: the plugin also models it as a body
        # on the JSON log `GET`, which the transport refuses to send.
        #
        # @example
        #   cmd.read(:stdout, offset: -4096)  # the last 4 KiB
        #   cmd.read(:stderr, offset: 0, limit: 1024)
        # @param stream [Symbol, String] `:stdout` or `:stderr`
        # @param offset [Integer, nil] first byte; negative counts back from
        #   the end, and then cannot be combined with `limit`
        # @param limit [Integer, nil] at most this many bytes
        # @return [String] binary
        # @raise [Unikraft::Cloud::Error] kind `:config` for an unusable range
        def read(stream = :stdout, offset: nil, limit: nil, **call)
          api.get_raw_command_log(uuid:, stream: stream.to_s, range: range(offset, limit), **call)
        end

        # Feed data into the command's standard input. Text and binary
        # Strings are both sent as their bytes.
        #
        # @param data [String]
        # @param eof [Boolean] close standard input afterwards
        # @return [self]
        def write(data, eof: false, **call)
          body = { data: Core::Base64.encode(data) }
          body[:eof] = true if eof
          unwrap(api.write_command_stdin(uuid:, body:, **call))
          self
        end

        # Close the command's standard input.
        #
        # @return [self]
        def close_write(**call) = write("", eof: true, **call)

        # Send a signal, by name or number.
        #
        # @example
        #   cmd.signal(:TERM)   # or "SIGTERM", or 15
        # @param signal [Symbol, String, Integer]
        # @return [self]
        def signal(signal, **call)
          signal = signal.to_s if signal.is_a?(Symbol)
          unwrap(api.signal_command(uuid:, body: { signal: }, **call))
          self
        end

        # Delete the command record and its logs. A running command cannot be
        # deleted (409).
        #
        # @return [nil]
        def delete(**call)
          unwrap(api.delete_command_by_uuid(uuid:, **call))
          nil
        end

        # Delete the command's logs, keeping its record.
        #
        # @return [nil]
        def delete_logs(**call)
          unwrap(api.delete_command_logs_by_uuid(uuid:, **call))
          nil
        end

        def inspect = "#<#{self.class.name} #{uuid} sandbox=#{sandbox.uuid}>"

        private

        def api = sandbox.api.commands

        def unwrap(res) = Core::Response.unwrap(res)

        # The `Range` header for a byte range of a log stream.
        def range(offset, limit)
          return nil if offset.nil? && limit.nil?

          { offset:, limit: }.each do |name, value|
            next if value.nil? || value.is_a?(Integer)

            raise Error.new("`#{name}:` must be a whole number of bytes. Received " \
                            "#{value.inspect}.", kind: :config)
          end
          if limit && limit <= 0
            raise Error.new("A `limit:` of #{limit} asks for no bytes at all; omit it to read " \
                            "to the end of the stream.", kind: :config)
          end
          start = offset || 0
          return "bytes=#{start}-#{limit && (start + limit - 1)}" unless start.negative?
          return "bytes=#{start}" if limit.nil?

          raise Error.new("A negative `offset:` already names the last bytes of the stream, " \
                          "so it cannot be combined with `limit:`.", kind: :config)
        end
      end
    end
  end
end
