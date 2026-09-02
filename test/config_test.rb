# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "test_helper"
require "robur/config"

class ConfigTest < Minitest::Test
  # Independent bash oracle: replicate parse_repo_conf + `declare -p` in bash,
  # compare every allowlisted key against the Ruby parse.
  def bash_parse(conf_path)
    script = <<~SH
      source #{File.expand_path("../../ratchet/lib/contract.sh", __dir__)}
      parse_repo_conf #{conf_path} || true
      for k in $CONTRACT_KEYS COOLDOWN_ZAI; do printf '%s=%s\n' "$k" "${!k}"; done
    SH
    Open3.capture3("bash", "-c", script).first.lines.each_with_object({}) do |l, h|
      k, v = l.chomp.split("=", 2)
      h[k] = v
    end
  end

  def test_repo_conf_matches_bash_parser
    conf = File.expand_path("../../ratchet/.ratchet.conf", __dir__)
    values, errors = Robur::Config.parse_repo(File.read(conf))
    assert_empty errors
    expected = bash_parse(conf)
    expected.each do |k, v|
      next unless Robur::Config.key_allowed?(k)
      # keys the real conf doesn't set resolve to "" in bash
      assert_equal v, values[k] || "", "key #{k}"
    end
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

  private

  def with_home(home)
    FileUtils.mkdir_p(File.join(home, ".ratchet"))
    old = ENV["HOME"]
    ENV["HOME"] = home
    yield
  ensure
    ENV["HOME"] = old
  end

  def test_precedence_cli_over_repo_over_global_over_defaults
    Dir.mktmpdir do |d|
      with_home(File.join(d, "home")) do
        File.write(File.join(ENV["HOME"], ".ratchet", "conf"), "PR_SOFT_MAX_LINES=300\nSTEP_TOKEN=GLOBAL\n")
        File.write(File.join(d, ".ratchet.conf"), "PR_SOFT_MAX_LINES=200\n")

        # all four layers set → CLI wins
        r = Robur::Config.load(d, "PR_SOFT_MAX_LINES" => "100")
        assert_equal "100", r.values["PR_SOFT_MAX_LINES"]
        # three layers → repo conf wins
        r = Robur::Config.load(d)
        assert_equal "200", r.values["PR_SOFT_MAX_LINES"]
        # two layers → global conf wins
        FileUtils.rm(File.join(d, ".ratchet.conf"))
        r = Robur::Config.load(d)
        assert_equal "300", r.values["PR_SOFT_MAX_LINES"]
        assert_equal "GLOBAL", r.values["STEP_TOKEN"]
        # one layer → defaults; VERIFY_CMD defaults empty (loud warning)
        FileUtils.rm(File.join(ENV["HOME"], ".ratchet", "conf"))
        r = Robur::Config.load(d)
        assert_equal "400", r.values["PR_SOFT_MAX_LINES"]
        assert_equal "", r.values["VERIFY_CMD"]
        assert_equal "STEP_COMPLETE", r.values["STEP_TOKEN"]
        assert_equal "1800", r.values["TURN_TIMEOUT"]
      end
    end
  end

  def test_defaults_declared_once
    # PR_SOFT_MAX_LINES default literal appears exactly once in lib/
    count = Dir[File.expand_path("../lib/**/*.rb", __dir__)].sum do |f|
      File.read(f).scan(/\b400\b/).count
    end
    assert_equal 1, count
  end

  def test_non_allowlisted_key_rejected_and_never_assigned
    Dir.mktmpdir do |d|
      File.write(File.join(d, ".ratchet.conf"), "MODELS=zai/m1\n")
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
end
