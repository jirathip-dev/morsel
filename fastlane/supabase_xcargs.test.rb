# frozen_string_literal: true

# Executable regression coverage for issue #32: native-testflight archives
# must receive the public Supabase endpoint/anon key from repository secrets
# with fail-fast, names-only diagnostics, the canonical Fly MORSEL_MCP_URL
# (issue #75; no SUPABASE_URL-derived Edge URL), and a no-log delivery
# (values live only in the Morsel Info.plist FILE, never on
# xcodebuild/Fastlane command lines or logs, and the committed no-value
# template is restored after success or failure).
#
# The real fastlane/Fastfile is loaded with minimal DSL stubs (lane bodies are
# never executed) so the actual production helpers are what the tests exercise.
#
# Run: mise exec ruby@4.0.5 -- ruby fastlane/supabase_xcargs.test.rb

require "minitest/autorun"
require "shellwords"
require "tmpdir"
require "open3"

# Minimal fastlane DSL surface so Fastfile loads outside a lane run.
module UI
  class << self
    attr_reader :messages

    def user_error!(message)
      raise message
    end

    def message(text)
      @messages ||= []
      @messages << text
    end
    alias important message
    alias success message
  end
end

def default_platform(*); end

def platform(*); end

def desc(*); end

def lane(*); end

FASTFILE = File.expand_path("Fastfile", __dir__)
load FASTFILE

TEMPLATE_PATH = MORSEL_INFO_PLIST
COMMITTED_TEMPLATE = File.binread(TEMPLATE_PATH)

class SupabaseValuesTest < Minitest::Test
  def setup
    ENV.delete("SUPABASE_URL")
    ENV.delete("SUPABASE_ANON_KEY")
    UI.messages&.clear
    restore_template!
  end

  def teardown
    restore_template!
  end

  def restore_template!
    File.binwrite(TEMPLATE_PATH, COMMITTED_TEMPLATE)
  end

  def test_missing_values_fail_before_gym_with_names_only_diagnostics
    error = assert_raises(RuntimeError) { morsel_supabase_values }
    assert_includes error.message, "SUPABASE_URL"
    assert_includes error.message, "SUPABASE_ANON_KEY"
  end

  def test_empty_values_fail_before_gym
    ENV["SUPABASE_URL"] = ""
    ENV["SUPABASE_ANON_KEY"] = "   "
    error = assert_raises(RuntimeError) { morsel_supabase_values }
    assert_includes error.message, "SUPABASE_URL"
    assert_includes error.message, "SUPABASE_ANON_KEY"
  end

  def test_blank_anon_key_with_valid_url_fails_naming_only_anon_key
    # Regression: a valid SUPABASE_URL with a blank/whitespace anon key must
    # fail listing only SUPABASE_ANON_KEY as missing (the URL guard must not
    # mask it). The guidance sentence may mention both names; the missing
    # list itself is what must name only the anon key.
    ENV["SUPABASE_URL"] = "https://abcd.supabase.co"
    ENV["SUPABASE_ANON_KEY"] = "   "
    error = assert_raises(RuntimeError) { morsel_supabase_values }
    assert_includes error.message, "SUPABASE_ANON_KEY"
    assert_includes error.message,
      "Missing required TestFlight configuration: SUPABASE_ANON_KEY."
    refute_includes error.message,
      "Missing required TestFlight configuration: SUPABASE_URL"
  end

  def test_mcp_url_defaults_to_canonical_fly_url
    ENV["SUPABASE_URL"] = "https://abcd.supabase.co"
    ENV["SUPABASE_ANON_KEY"] = "anon-key"
    values = morsel_supabase_values
    assert_equal "https://morsel-mcp.fly.dev/mcp", values[:mcp_url]
    refute_includes values[:mcp_url], "supabase.co"
  end

  def test_mcp_url_is_independent_of_supabase_url_shape
    ENV["SUPABASE_URL"] = "https://abcd.supabase.co/"
    ENV["SUPABASE_ANON_KEY"] = "anon-key"
    assert_equal "https://morsel-mcp.fly.dev/mcp",
      morsel_supabase_values[:mcp_url]
  end

  def test_template_stays_no_value_after_success
    ENV["SUPABASE_URL"] = "https://abcd.supabase.co"
    ENV["SUPABASE_ANON_KEY"] = "anon-key"
    with_morsel_supabase_plist { nil }
    assert_equal COMMITTED_TEMPLATE, File.binread(TEMPLATE_PATH),
      "template must be restored byte-identical after success"
    refute_includes File.binread(TEMPLATE_PATH), "anon-key"
    refute_includes File.binread(TEMPLATE_PATH), "abcd.supabase.co"
  end

  def test_template_stays_no_value_after_block_failure
    ENV["SUPABASE_URL"] = "https://abcd.supabase.co"
    ENV["SUPABASE_ANON_KEY"] = "anon-key"
    assert_raises(RuntimeError) do
      with_morsel_supabase_plist { raise "simulated gym failure" }
    end
    assert_equal COMMITTED_TEMPLATE, File.binread(TEMPLATE_PATH),
      "template must be restored byte-identical after failure"
    refute_includes File.binread(TEMPLATE_PATH), "anon-key"
  end

  def test_values_reach_the_plist_file_during_yield_only
    ENV["SUPABASE_URL"] = "https://abcd.supabase.co"
    ENV["SUPABASE_ANON_KEY"] = "anon-key"
    seen = nil
    with_morsel_supabase_plist { seen = File.binread(TEMPLATE_PATH) }
    assert_includes seen, "<key>MorselSupabaseURL</key>"
    assert_includes seen, "<string>https://abcd.supabase.co</string>"
    assert_includes seen, "<string>anon-key</string>"
    assert_includes seen,
      "<string>https://morsel-mcp.fly.dev/mcp</string>"
  end

  def test_shell_sensitive_values_are_never_executed_or_split
    sentinel = File.join(Dir.tmpdir, "morsel-pwned-#{Process.pid}")
    File.delete(sentinel) if File.exist?(sentinel)
    hostile = "abc def;$(touch #{sentinel})&`echo hi`\"q\"'q'<&>"
    ENV["SUPABASE_URL"] = "https://abcd.supabase.co"
    ENV["SUPABASE_ANON_KEY"] = hostile
    seen = nil
    round_tripped = nil
    with_morsel_supabase_plist do
      seen = File.binread(TEMPLATE_PATH)
      round_tripped = plist_xml_value(TEMPLATE_PATH, "MorselSupabaseAnonKey")
    end
    refute File.exist?(sentinel), "values must never be executed"
    # The hostile value must be embedded as an XML-escaped literal string.
    assert_includes seen, "<string>abc def;$(touch #{sentinel})&amp;`echo hi`&quot;q&quot;'q'&lt;&amp;&gt;</string>"
    # And it must round-trip through a plist/XML parser back to the exact
    # value (REXML unescapes entities), proving it is data, not code.
    assert_equal hostile, round_tripped
    assert_equal COMMITTED_TEMPLATE, File.binread(TEMPLATE_PATH),
      "template restored after yield"
  ensure
    File.delete(sentinel) if File.exist?(sentinel)
  end

  def test_diagnostics_never_reveal_the_anon_key
    ENV["SUPABASE_URL"] = ""
    ENV["SUPABASE_ANON_KEY"] = "super-secret-anon-value"
    error = assert_raises(RuntimeError) { morsel_supabase_values }
    refute_includes error.message, "super-secret-anon-value"
    refute(UI.messages&.any? { |m| m.include?("super-secret-anon-value") })
  end

  def test_production_code_has_no_value_echo_path
    fastfile = File.read(FASTFILE)
    # The lane's gym xcargs must carry no Supabase values at all.
    refute_match(/xcargs:.*MORSEL_SUPABASE|xcconfig/, fastfile)
    # No puts/UI.message of the values anywhere in the helpers.
    refute_match(/UI\.message\([^)]*(url|anon|mcp)/, fastfile)
    refute_match(/puts\s+.*(anon_key|supabase_url|values\[)/, fastfile)
  end

  private

  # Read a top-level <key>...</key><string>...</string> value from the plist
  # via stdlib REXML, which unescapes XML entities. Portable (no PlistBuddy).
  def plist_xml_value(plist_path, key)
    require "rexml/document"
    doc = REXML::Document.new(File.read(plist_path))
    nodes = doc.get_elements("//key")
    idx = nodes.index { |node| node.text == key }
    raise "key #{key} not found in plist" unless idx

    nodes[idx].next_element&.text
  end
end
