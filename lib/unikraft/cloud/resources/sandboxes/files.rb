# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.
#
# The filesystem inside a sandbox, in the shape of Ruby's own File.

require_relative "../../core/base64"
require_relative "../../core/response"

module Unikraft
  module Cloud
    class Sandbox
      # The sandbox's filesystem, as `sb.files`. Paths are absolute paths
      # inside the sandbox. Data is a String, or anything that responds to
      # `read`, such as an open File: a binary String (`Encoding::BINARY`)
      # travels as bytes, any other String as UTF-8 text.
      #
      # @example
      #   sb.files.mkdir("/work/input")
      #   sb.files.write("/work/input/a.txt", "hello\n")
      #   sb.files.write("/work/input/a.txt", "more\n", append: true)
      #   sb.files.upload("/work/input", "data.bin", File.binread("data.bin"))
      #   sb.files.read("/work/input/a.txt")   # => "hello\nmore\n" (binary)
      class Files
        # @api private
        def initialize(sandbox)
          @sandbox = sandbox
        end

        # Read a file.
        #
        # @param path [String]
        # @param call [Hash] `headers:`, `timeout:`
        # @return [String] the contents, binary
        def read(path, **call)
          # The raw read, not the base64 one, which costs a third more bytes.
          api.read_raw_file(body: { path: }, **call)
        end

        # Write a file, creating it if it is missing.
        #
        # @param path [String]
        # @param data [String, #read]
        # @param append [Boolean] append rather than truncate
        # @return [nil]
        def write(path, data, append: false, **call)
          Core::Response.unwrap(api.write_file(body: { path:, append:, **encode(data) }, **call))
          nil
        end

        # Create a directory, and its missing parents unless `parents: false`.
        #
        # @param path [String]
        # @param parents [Boolean]
        # @return [nil]
        def mkdir(path, parents: true, **call)
          Core::Response.unwrap(api.create_directory(body: { path:, parents: }, **call))
          nil
        end

        # Upload a file: into the directory `path` under `filename`, or to
        # `path` itself when that is not a directory.
        #
        # @param path [String]
        # @param filename [String]
        # @param data [String, #read]
        # @param parents [Boolean] create missing parent directories
        # @return [nil]
        def upload(path, filename, data, parents: true, **call)
          body = { path:, filename:, parents:, **encode(data) }
          Core::Response.unwrap(api.upload_file(body:, **call))
          nil
        end

        def inspect = "#<#{self.class.name} sandbox=#{@sandbox.uuid}>"

        private

        def api = @sandbox.api.fs

        # The encoding and payload the filesystem API wants for some data.
        def encode(data)
          data = data.read if data.respond_to?(:read)
          data = data.to_s
          if data.encoding == Encoding::BINARY || !data.valid_encoding?
            { encoding: "base64", data: Core::Base64.encode(data) }
          else
            { encoding: "utf-8", data: data.encode(Encoding::UTF_8) }
          end
        end
      end
    end
  end
end
