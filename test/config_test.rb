# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "test_helper"
require "robur/config"
require "robur/paths"

class ConfigTest < Minitest::Test
  # Runs the block with $HOME pointed at a scratch dir holding a global conf,
  # so the home layer is exercised without touching the real one. Defined
  # BEFORE the tests and left public on purpose: a `private` section here once
  # silently hid every test method declared after it from minitest.
  def with_home(home, dir_name = Robur::Paths::HOME_DIR)
    FileUtils.mkdir_p(File.join(home, dir_name))
    old = ENV["HOME"]
    ENV["HOME"] = home
    yield File.join(home, dir_name, "conf")
  ensure
    ENV["HOME"] = old
  end

  def test_global_conf_env_and_values_match_bash_source
    global = File.expand_path("~/.ratchet/conf")
    skip unless File.file?(global)
    result = Robur::Config.load_global(global)
    assert_empty result[:errors]

    # exported vars become the environment (independently dumped via env -0)
    bash_env, = Open3.capture3("bash", "-c",
      'env -0; printf "\0--\0"; . "' + global + '"; env -0')
    before, after = bash_env.split("\0--\0").map { |s| s.split("\0").to_h { |p| p.split("=", 2) } }
    expected_env = after.select { |k, v| before[k] != v }
    expected_env.delete("SHLVL") # process noise, not config
    assert_equal expected_env, result[:env].tap { |h| h.delete("SHLVL") }
    assert result[:env].key?("PATH"), "PATH shim export must reach spawned-turn env"

    # every resolved value the bash source produces appears in declare -p output
    declares, = Open3.capture3("bash", "-c", %Q{. "#{global}"; declare -p})
    result[:values].each do |k, v|
      # dynamic vars (EPOCHREALTIME, SECONDS…) have values but no declare -p entry
      next unless declares.match?(/declare \S+ #{Regexp.escape(k)}=/)
      assert_includes declares, v, "value of #{k} not produced by bash source"
    end
    # known plain assignments become config values
    assert_equal "off", result[:values]["THINKING_LIGHT"]
    assert_includes result[:values]["MODELS"], "zai/glm"
  end

  def test_precedence_cli_over_repo_over_global_over_defaults
    Dir.mktmpdir do |d|
      with_home(File.join(d, "home")) do |global_conf|
        repo_conf = File.join(d, Robur::Paths::REPO_CONF)
        File.write(global_conf, "PR_SOFT_MAX_LINES=300\nSTEP_TOKEN=GLOBAL\n")
        File.write(repo_conf, "PR_SOFT_MAX_LINES=200\n")

        # all four layers set → CLI wins
        r = Robur::Config.load(d, "PR_SOFT_MAX_LINES" => "100")
        assert_equal "100", r.values["PR_SOFT_MAX_LINES"]
        # three layers → repo conf wins
        r = Robur::Config.load(d)
        assert_equal "200", r.values["PR_SOFT_MAX_LINES"]
        # two layers → global conf wins
        FileUtils.rm(repo_conf)
        r = Robur::Config.load(d)
        assert_equal "300", r.values["PR_SOFT_MAX_LINES"]
        assert_equal "GLOBAL", r.values["STEP_TOKEN"]
        # one layer → defaults; VERIFY_CMD defaults empty (loud warning)
        FileUtils.rm(global_conf)
        r = Robur::Config.load(d)
        assert_equal "400", r.values["PR_SOFT_MAX_LINES"]
        assert_equal "", r.values["VERIFY_CMD"]
        assert_equal "STEP_COMPLETE", r.values["STEP_TOKEN"]
        assert_equal "1800", r.values["TURN_TIMEOUT"]
      end
    end
  end

  # A default belongs in exactly ONE place: a second copy drifts, and the two
  # halves of the product then disagree about what the default is. Matched on
  # the key, not the bare literal — "400" also appears in prose and in an HTTP
  # status pattern, neither of which is a declaration of this default.
  # The global conf is sourced in a SUBPROCESS, so nothing in it -- not even an
  # export -- reaches this process's ENV on its own, and no caller of `robur`
  # sources it either. The bridge is therefore the only path by which
  # NOTIFY_CMD can ever arrive.
  def test_global_only_key_is_bridged_into_env
    Dir.mktmpdir do |d|
      with_home(File.join(d, "home")) do |global_conf|
        File.write(global_conf, "NOTIFY_CMD='/bin/echo hi'\n")
        with_clean_env("NOTIFY_CMD") do
          Robur::Config.load(d)
          assert_equal "/bin/echo hi", ENV["NOTIFY_CMD"],
                       "a plain assignment in the trusted global conf must reach ENV"
        end
      end
    end
  end

  def test_exported_and_plain_forms_are_equivalent
    Dir.mktmpdir do |d|
      with_home(File.join(d, "home")) do |global_conf|
        File.write(global_conf, "export NOTIFY_CMD='/bin/echo exported'\n")
        with_clean_env("NOTIFY_CMD") do
          Robur::Config.load(d)
          assert_equal "/bin/echo exported", ENV["NOTIFY_CMD"]
        end
      end
    end
  end

  def test_inherited_env_wins_over_the_conf
    Dir.mktmpdir do |d|
      with_home(File.join(d, "home")) do |global_conf|
        File.write(global_conf, "NOTIFY_CMD='/from/conf'\n")
        with_clean_env("NOTIFY_CMD") do
          ENV["NOTIFY_CMD"] = "/from/shell"
          Robur::Config.load(d)
          assert_equal "/from/shell", ENV["NOTIFY_CMD"],
                       "an operator's explicit export is the more immediate intent"
        end
      end
    end
  end

  # The whole point of the allowlist: this runs a shell command, and an agent
  # can write the repo conf. Bridging must not open a second door.
  def test_repo_conf_can_never_set_a_global_only_key
    Dir.mktmpdir do |d|
      with_home(File.join(d, "home")) do |global_conf|
        File.write(global_conf, "STEP_TOKEN=X\n")
        File.write(File.join(d, Robur::Paths::REPO_CONF), "NOTIFY_CMD='/pwn'\n")
        with_clean_env("NOTIFY_CMD") do
          r = Robur::Config.load(d)
          assert_nil ENV["NOTIFY_CMD"], "repo conf must never reach ENV"
          refute_equal "/pwn", r.values["NOTIFY_CMD"]
          assert r.errors.any? { |e| e.include?("NOTIFY_CMD") },
                 "a rejected repo-conf key must be a loud doctor error, got #{r.errors.inspect}"
        end
      end
    end
  end

  def with_clean_env(*keys)
    saved = keys.to_h { |k| [k, ENV[k]] }
    keys.each { |k| ENV.delete(k) }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def test_defaults_declared_once
    declarations = Dir[File.expand_path("../lib/**/*.rb", __dir__)].flat_map do |f|
      File.readlines(f).grep(/PR_SOFT_MAX_LINES["']?\s*(=>|=|:)\s*["']?\d/)
    end

    assert_equal 1, declarations.count, "PR_SOFT_MAX_LINES default declared more than once: #{declarations}"
    assert_includes declarations.first, "400"
  end

  def test_non_allowlisted_key_rejected_and_never_assigned
    Dir.mktmpdir do |d|
      File.write(File.join(d, Robur::Paths::REPO_CONF), "MODELS=zai/m1\n")
      values, errors = Robur::Config.parse_repo("NOTIFY_CMD=x\nMODELS=zai/m1\n")
      assert_nil values["NOTIFY_CMD"] # never assigned
      assert_includes errors.join("\n"), "unknown key 'NOTIFY_CMD'"
      result = Robur::Config.load(d)
      assert_equal "zai/m1", result.values["MODELS"] # repo conf overrides global
      assert_empty result.errors.select { |e| e.include?("NOTIFY_CMD") }
    end
  end

  def test_parse_rules
    values, errors = Robur::Config.parse_repo(<<~'CONF')
      # comment line
      STEP_TOKEN="hello world"
      AGENT_CMD='it\'s'
      COOLDOWN_ZAI=900
      COOLDOWN_x=1
      TURN_TIMEOUT=12ab
      VERIFY_CMD=ruby -e 'puts #{1+1}'
      oops
      BAD KEY=x
    CONF
    assert_equal({ "STEP_TOKEN" => "hello world", "AGENT_CMD" => "it\\'s", "COOLDOWN_ZAI" => "900",
                   "TURN_TIMEOUT" => "12", "VERIFY_CMD" => "ruby -e 'puts " }, values) # truncated at first #, like bash ${line%%#*}
    assert_equal 3, errors.length
    assert_includes errors.join("\n"), "unknown key 'COOLDOWN_x'"
    assert_includes errors.join("\n"), "not a KEY=value line: 'oops'"
    assert_includes errors.join("\n"), "unknown key 'BAD KEY'"
  end
  def test_conf_hash_matches_shasum
    Dir.mktmpdir do |d|
      conf = File.join(d, Robur::Paths::REPO_CONF)
      File.write(conf, "MODELS=zai/m1\n")
      expected = `shasum -a 256 #{conf} | awk '{print $1}'`.strip
      assert_equal expected, Robur::Config.conf_hash(conf)
      assert_equal "none", Robur::Config.conf_hash(File.join(d, "missing"))
    end
  end

  def test_conf_hash_round_trip_and_one_line_format
    Dir.mktmpdir do |d|
      conf = File.join(d, Robur::Paths::REPO_CONF)
      File.write(conf, "STEP_TOKEN=X\n")
      Robur::Config.write_conf_hash(d)
      stamp = Robur::Paths.state_file(d, "conf.hash")

      # one bare sha256 on one line — the format every external reader parses
      assert_equal `shasum -a 256 #{conf} | awk '{print $1}'`.strip, File.read(stamp).strip
      assert_equal 1, File.read(stamp).lines.count

      # a stamp written by any other tool reads back and matches → no tampering
      File.write(stamp, `shasum -a 256 #{conf} | awk '{print $1}'`)

      assert_equal Robur::Config.conf_hash(conf), Robur::Config.read_conf_hash(d)
    end
  end

  # Backward compatibility: a repo and a home that never migrated hold only
  # `.ratchet.conf` and `~/.ratchet/conf`. Both layers must still load, in the
  # same precedence order, with no migration step in between.
  def test_legacy_conf_names_still_load_at_both_layers
    Dir.mktmpdir do |d|
      with_home(File.join(d, "home"), Robur::Paths::LEGACY_HOME_DIR) do |legacy_global|
        File.write(legacy_global, "PR_SOFT_MAX_LINES=300\nSTEP_TOKEN=GLOBAL\n")

        r = Robur::Config.load(d)

        assert_equal "300", r.values["PR_SOFT_MAX_LINES"]
        assert_equal "GLOBAL", r.values["STEP_TOKEN"]

        File.write(File.join(d, Robur::Paths::LEGACY_REPO_CONF), "PR_SOFT_MAX_LINES=200\n")
        r = Robur::Config.load(d)

        assert_equal "200", r.values["PR_SOFT_MAX_LINES"], "legacy repo conf must still beat the global layer"
      end
    end
  end

  # Both spellings of the protocol key are allowlisted: a conf written before
  # the rename must not start erroring, and a new one must not need the old
  # name to be accepted.
  def test_both_protocol_key_spellings_are_accepted
    %w[ROBUR_PROTOCOL RATCHET_PROTOCOL].each do |key|
      values, errors = Robur::Config.parse_repo("#{key}=1\n")

      assert_empty errors, "#{key} must be allowlisted"
      assert_equal "1", values[key]
      assert Robur::Config.key_allowed?(key)
    end
  end
end
