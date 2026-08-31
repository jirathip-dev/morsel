# frozen_string_literal: true

# Executable regression coverage for issue #32: native-testflight archives
# must receive the public Supabase endpoint/anon key from repository secrets
# with fail-fast, names-only diagnostics, a correctly derived MORSEL_MCP_URL,
# and shell-safe quoting so values can never be executed or split.
#
# The real fastlane/Fastfile is loaded with minimal DSL stubs (lane bodies are
# never executed) so the actual `morsel_supabase_xcargs` production helper is
# what the tests exercise, not a copy.
#
# Run: mise exec ruby@4.0.5 -- ruby fastlane/supabase_xcargs.test.rb

require "minitest/autorun"
require "shellwords"
require "tmpdir"

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

class SupabaseXcargsTest < Minitest::Test
  def setup
    ENV.delete("SUPABASE_URL")
    ENV.delete("SUPABASE_ANON_KEY")
    UI.messages&.clear
  end

  def test_missing_values_fail_before_gym_with_names_only_diagnostics
    error = assert_raises(RuntimeError) { morsel_supabase_xcargs(1) }
    assert_includes error.message, "SUPABASE_URL"
    assert_includes error.message, "SUPABASE_ANON_KEY"
  end

  def test_empty_values_fail_before_gym
    ENV["SUPABASE_URL"] = ""
    ENV["SUPABASE_ANON_KEY"] = "   "
    error = assert_raises(RuntimeError) { morsel_supabase_xcargs(1) }
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
    error = assert_raises(RuntimeError) { morsel_supabase_xcargs(1) }
    assert_includes error.message, "SUPABASE_ANON_KEY"
    assert_includes error.message,
      "Missing required TestFlight configuration: SUPABASE_ANON_KEY."
    refute_includes error.message,
      "Missing required TestFlight configuration: SUPABASE_URL"
  end

  def test_derives_mcp_url_from_supabase_url
    ENV["SUPABASE_URL"] = "https://abcd.supabase.co"
    ENV["SUPABASE_ANON_KEY"] = "anon-key"
    xcargs = morsel_supabase_xcargs(3)
    assert_includes xcargs,
      "MORSEL_MCP_URL=https://abcd.supabase.co/functions/v1/mcp"
  end

  def test_trailing_slash_does_not_create_double_slash
    ENV["SUPABASE_URL"] = "https://abcd.supabase.co/"
    ENV["SUPABASE_ANON_KEY"] = "anon-key"
    xcargs = morsel_supabase_xcargs(3)
    assert_includes xcargs,
      "MORSEL_MCP_URL=https://abcd.supabase.co/functions/v1/mcp"
    refute_includes xcargs, "//functions/v1/mcp"
  end

  def test_all_overrides_and_build_number_reach_xcargs
    ENV["SUPABASE_URL"] = "https://abcd.supabase.co"
    ENV["SUPABASE_ANON_KEY"] = "anon-key"
    xcargs = morsel_supabase_xcargs(42)
    assert_includes xcargs, "CURRENT_PROJECT_VERSION=42"
    assert_includes xcargs, "INFOPLIST_FILE="
    assert_includes xcargs, "MORSEL_SUPABASE_URL=https://abcd.supabase.co"
    assert_includes xcargs, "MORSEL_SUPABASE_ANON_KEY=anon-key"
    assert_includes xcargs,
      "MORSEL_MCP_URL=https://abcd.supabase.co/functions/v1/mcp"
    # The old INFOPLIST_KEY_<custom> delivery is gone: Xcode silently drops it.
    refute_includes xcargs, "INFOPLIST_KEY_MorselSupabaseURL"
    refute_includes xcargs, "INFOPLIST_KEY_MorselSupabaseAnonKey"
    refute_includes xcargs, "INFOPLIST_KEY_MORSEL_MCP_URL"
  end

  def test_template_exists_and_points_at_committed_fixture
    ENV["SUPABASE_URL"] = "https://abcd.supabase.co"
    ENV["SUPABASE_ANON_KEY"] = "anon-key"
    xcargs = morsel_supabase_xcargs(1)
    plist_path = xcargs[/INFOPLIST_FILE=(.+?)(?:\s|$)/, 1]
    refute_nil plist_path, "INFOPLIST_FILE must point at the template"
    assert File.exist?(plist_path), "template #{plist_path} must exist"
    template = File.read(plist_path)
    assert_includes template, "<key>MorselSupabaseURL</key>"
    assert_includes template, "$(MORSEL_SUPABASE_URL)"
    assert_includes template, "<key>MorselSupabaseAnonKey</key>"
    assert_includes template, "$(MORSEL_SUPABASE_ANON_KEY)"
    assert_includes template, "<key>MORSEL_MCP_URL</key>"
    assert_includes template, "$(MORSEL_MCP_URL)"
  end

  def test_shell_sensitive_values_are_quoted_not_executed_or_split
    sentinel = File.join(Dir.tmpdir, "morsel-pwned-#{Process.pid}")
    File.delete(sentinel) if File.exist?(sentinel)
    ENV["SUPABASE_URL"] = "https://abcd.supabase.co"
    ENV["SUPABASE_ANON_KEY"] = "abc def;$(touch #{sentinel})&`echo hi`\"q\"'q'"
    xcargs = morsel_supabase_xcargs(1)
    # Shellwords.split must recover exactly the same tokens: no splitting, no
    # execution, no mangling of shell metacharacters.
    tokens = Shellwords.split(xcargs)
    assert_includes tokens,
      "MORSEL_SUPABASE_ANON_KEY=abc def;$(touch #{sentinel})&`echo hi`\"q\"'q'"
    refute File.exist?(sentinel), "shell metacharacters must not be executed"
    refute_includes xcargs, "CURRENT_PROJECT_VERSION=1 abc", "value must be quoted, not split"
  end

  def test_diagnostics_never_reveal_the_anon_key
    ENV["SUPABASE_URL"] = ""
    ENV["SUPABASE_ANON_KEY"] = "super-secret-anon-value"
    error = assert_raises(RuntimeError) { morsel_supabase_xcargs(1) }
    refute_includes error.message, "super-secret-anon-value"
    refute(UI.messages&.any? { |m| m.include?("super-secret-anon-value") })
  end
end
