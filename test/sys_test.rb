# frozen_string_literal: true

require_relative "test_helper"
require "robur/sys"
require "socket"
require "tempfile"

# minimal consumer exercising the `sys:` injection seam
class Sleeper
  def initialize(sys:) = (@clock = sys.clock)
  def nap = @clock.sleep(0.5)
end

class SysDouble
  def clock = @clock ||= Class.new(Robur::Sys::Clock) do
    attr_reader :slept

    def initialize = @slept = []
    def sleep(s) = @slept << s
  end.new
end

module Robur
  class SysTest < Minitest::Test
    def test_clock_double_records_sleeps_without_real_time
      sys = SysDouble.new
      sleeper = Sleeper.new(sys: sys)
      t0 = Sys::Clock.new.monotonic
      sleeper.nap
      assert_operator Sys::Clock.new.monotonic - t0, :<, 0.4
      assert_equal [0.5], sys.clock.slept
    end

    def test_fs_roundtrip_and_glob
      fs = Sys::Fs.new
      dir = File.join(Dir.mktmpdir, "a/b")
      fs.mkdir_p(dir)
      path = File.join(dir, "f.txt")
      fs.write(path, "hi")
      assert fs.exist?(path)
      assert_equal "hi", fs.read(path)
      assert_equal [path], fs.glob(File.join(dir, "*.txt"))
    end

    def test_capture
      out, err, st = Sys::Proc.new.capture("echo", "ok")
      assert_equal "ok\n", out
      assert_equal "", err
      assert_predicate st, :success?
    end

    def test_spawn_with_deadline_completes
      out, _err, st = Sys::Proc.new.spawn_with_deadline("echo ok", deadline: 5)
      assert_equal "ok\n", out
      assert_predicate st, :success?
    end

    def test_spawn_with_deadline_kills_hangers
      proc = Sys::Proc.new
      clock = Sys::Clock.new
      t = clock.monotonic
      _out, _err, st = proc.spawn_with_deadline("sleep 30", deadline: 0.3)
      assert_operator clock.monotonic - t, :<, 5
      refute_predicate st, :success?
    end

    def test_http_get_local
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      thr = Thread.new do
        sock = server.accept
        sock.readpartial(4096)
        sock.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")
        sock.close
      end
      res = Sys::Http.new.get("http://127.0.0.1:#{port}/")
      thr.join
      assert_equal "200", res.code
      assert_equal "hi", res.body
    ensure
      server&.close
    end
  end
end
