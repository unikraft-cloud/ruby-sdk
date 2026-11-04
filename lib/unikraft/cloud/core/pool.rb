# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

module Unikraft
  module Cloud
    module Core
      # The idle, started Net::HTTP connections of one {ApiClient}, by
      # destination. A connection is either checked out by exactly one
      # thread or idle here, never both, so no two threads share one.
      class Pool
        # Idle connections kept per destination; more are closed on checkin.
        MAX_IDLE = 8

        # Seconds a connection may sit idle before it is discarded. Below
        # the idle timeout of typical servers and load balancers, so the
        # server rarely closes a connection first.
        KEEP_ALIVE = 5

        # @return [Numeric] the keep-alive window in seconds
        attr_reader :keep_alive

        # @param max_idle [Integer] idle connections kept per key
        # @param keep_alive [Numeric] seconds an idle connection is kept
        def initialize(max_idle: MAX_IDLE, keep_alive: KEEP_ALIVE)
          @max_idle = max_idle
          @keep_alive = keep_alive
          @mutex = Mutex.new
          @idle = Hash.new { |h, k| h[k] = [] }
          @pid = Process.pid
        end

        # Take the most recently used idle connection for key, closing the
        # expired ones on the way.
        #
        # @return [Net::HTTP, nil] nil when none is idle
        def checkout(key)
          expired = []
          http = @mutex.synchronize do
            forget_if_forked
            idle = @idle[key]
            while (entry = idle.pop)
              break entry[0] if now - entry[1] < @keep_alive

              expired << entry[0]
            end
          end
          expired.each { |c| discard(c) }
          http
        end

        # Return a connection that finished its exchange cleanly.
        def checkin(key, http)
          kept = @mutex.synchronize do
            forget_if_forked
            idle = @idle[key]
            idle << [http, now] if idle.size < @max_idle
          end
          discard(http) unless kept
        end

        # Close a connection; never raises.
        def discard(http)
          http.finish
        rescue StandardError
          nil
        end

        # Close every idle connection. Idempotent; the pool stays usable.
        def close
          conns = @mutex.synchronize do
            forget_if_forked
            all = @idle.values.flatten(1).map(&:first)
            @idle.clear
            all
          end
          conns.each { |c| discard(c) }
          nil
        end

        private

        # A forked child shares its parent's sockets: closing them would
        # cut the parent's connections, so the child only forgets them.
        def forget_if_forked
          return if @pid == Process.pid

          @idle = Hash.new { |h, k| h[k] = [] }
          @pid = Process.pid
        end

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
