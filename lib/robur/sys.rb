# frozen_string_literal: true

require "fileutils"
require "open3"
require "net/http"
require "uri"

module Robur
  # Injected boundaries: filesystem, clock, subprocess, HTTP. Tests pass
  # doubles via `sys:`; defaults are the real implementations.
  module Sys
    # Read a file as UTF-8 with invalid bytes replaced.
    #
    # EVERY read of a loop.log or a turn file must go through this. Ruby
    # raises `ArgumentError: invalid byte sequence in UTF-8` the moment a
    # regex touches such a string, and real production logs DO contain
    # invalid bytes (agents stream partial UTF-8 sequences when a turn is
    # killed mid-write). Measured against a real production loop.log, that
    # crashed `status`, `stats` and the ETA path outright.
    #
    # Missing/unreadable file -> nil, never a raise, so callers treat it as
    # an absent section.
    def self.read_scrubbed(path)
      File.read(path, mode: "rb").force_encoding("UTF-8").scrub
    rescue StandardError
      nil
    end

    class Fs
      def read(path) = File.read(path)

      def write(path, content)
        File.write(path, content)
      end

      def exist?(path) = File.exist?(path)

      def mkdir_p(path) = FileUtils.mkdir_p(path)

      def glob(pattern) = Dir.glob(pattern)
    end

    class Clock
      def now = Time.now

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def sleep(seconds) = Kernel.sleep(seconds)
    end

    class Proc
      # returns [stdout, stderr, status]; forwards Open3.capture3 options
      # (chdir:, stdin_data:, ...) through unchanged.
      def capture(*cmd, **opts)
        Open3.capture3(*cmd, **opts)
      end

      def spawn(cmd, out:, err:, chdir: nil)
        opts = { out: out, err: err }
        opts[:chdir] = chdir if chdir
        Process.spawn(*cmd, **opts)
      end

      def reap(pid)
        Process.wait(pid)
        $?
      end

      # TERM, then poll for the exit instead of sleeping the whole grace out:
      # a TERM-responsive child dies in milliseconds and used to cost 2s every
      # time. A child that traps TERM still gets KILL at the ceiling, so the
      # escalation and the resulting wstatus are unchanged. Returns the reaped
      # status, or nil if there was nothing to reap (caller reaps instead).
      GRACE = 2.0
      TICK = 0.05

      def kill(pid)
        Process.kill("TERM", pid)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GRACE
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          return status if status

          sleep(TICK)
        end
        Process.kill("KILL", pid)
        Process.waitpid2(pid)[1]
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      # returns [stdout, stderr, status]; kills the process group at deadline.
      def spawn_with_deadline(cmd, deadline:, **opts)
        Open3.popen3(cmd, **opts.merge(pgroup: true)) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          status = wait_thr.join(deadline)&.value
          unless status
            begin
              Process.kill("TERM", -wait_thr.pid)
              status = wait_thr.join(1)&.value
              Process.kill("KILL", -wait_thr.pid) unless status
            rescue Errno::ESRCH
              # The process exited between join and signal.
            end
          end
          [stdout.read, stderr.read, status || wait_thr.value]
        end
      end
    end

    class Http
      def get(uri, headers: {})
        request(Net::HTTP::Get, uri, headers)
      end

      def post(uri, body:, headers: {})
        request(Net::HTTP::Post, uri, headers) { |req| req.body = body }
      end

      private

      def request(klass, uri, headers)
        uri = URI(uri)
        req = klass.new(uri)
        headers.each { |k, v| req[k] = v }
        yield req if block_given?
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(req)
        end
      end
    end
  end
end
