# frozen_string_literal: true

require "fileutils"
require "open3"
require "net/http"
require "uri"

module Robur
  # Injected boundaries: filesystem, clock, subprocess, HTTP. Tests pass
  # doubles via `sys:`; defaults are the real implementations.
  module Sys
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
      # returns [stdout, stderr, status]
      def capture(*cmd)
        Open3.capture3(*cmd)
      end

      # returns [stdout, stderr, status]; kills the process at the deadline.
      # ponytail: wait_thr.kill + no stdin pipe; no process-group kill, add
      # if a spawned command ever leaves grandchildren behind.
      def spawn_with_deadline(cmd, deadline:)
        Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          status = wait_thr.join(deadline)&.value
          Process.kill("TERM", wait_thr.pid) unless status
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
