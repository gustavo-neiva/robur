require_relative "test_helper"

class SmokeTest < Minitest::Test
  def test_version
    assert_equal "0.0.1", Robur::VERSION
  end
end
