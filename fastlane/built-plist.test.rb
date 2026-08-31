# frozen_string_literal: true

# REQUIRED BUILT-ARTIFACT GATE for issue #32: proves the three Supabase
# runtime keys land in the BUILT Morsel.app/Info.plist (not just in the
# Fastfile source or the helper's returned string). Xcode silently drops
# arbitrary INFOPLIST_KEY_<custom> build settings under
# GENERATE_INFOPLIST_FILE=YES, so this gate runs a real unsigned Xcode build
# with the real `morsel_supabase_xcargs` output and inspects the produced
# plist with PlistBuddy.
#
# No secrets: fixture values only. Skips cleanly when xcodebuild is absent
# (e.g. Linux CI) — on macOS it is a hard gate.
#
# Run: mise exec ruby@4.0.5 -- ruby fastlane/built-plist.test.rb

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

FIXTURE_URL = "https://fixture.supabase.co"
FIXTURE_ANON_KEY = "fixture-anon-key"
FIXTURE_BUILD = 42
CONTROL = "FIXTUREPROBE"

class BuiltPlistTest < Minitest::Test
  def setup
    ENV["SUPABASE_URL"] = FIXTURE_URL
    ENV["SUPABASE_ANON_KEY"] = FIXTURE_ANON_KEY
  end

  def teardown
    ENV.delete("SUPABASE_URL")
    ENV.delete("SUPABASE_ANON_KEY")
  end

  def xcodebuild_available?
    return false unless RbConfig::CONFIG["host_os"] =~ /darwin/i

    _out, status = Open3.capture2e("xcodebuild", "-version")
    status.success?
  end

  def build_morsel(extra_xcargs: [])
    derived = Dir.mktmpdir("morsel-built-plist")
    repo_root = File.expand_path("..", __dir__)
    xcargs = Shellwords.split(morsel_supabase_xcargs(FIXTURE_BUILD)) + extra_xcargs
    # Build unsigned; the generated Info.plist is identical pre/post signing.
    cmd = [
      "xcodebuild", "-project", "app/Morsel.xcodeproj", "-scheme", "Morsel",
      "-configuration", "Release", "-sdk", "iphoneos",
      "-destination", "generic/platform=iOS",
      "-derivedDataPath", derived,
      "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
      "CODE_SIGN_IDENTITY=", *xcargs, "build"
    ]
    _out, status = Open3.capture2e(*cmd, chdir: repo_root)
    [status, derived]
  end

  def built_plist(derived)
    Dir[File.join(derived, "Build/Products/Release-iphoneos/Morsel.app/Info.plist")].first
  end

  def plist_value(plist, key)
    out, status = Open3.capture2e("/usr/libexec/PlistBuddy", "-c", "Print :#{key}", plist)
    return nil unless status.success?

    out.strip
  end

  def test_built_plist_contains_all_three_fixture_keys
    skip "xcodebuild not available" unless xcodebuild_available?

    status, derived = build_morsel
    assert status.success?, "unsigned xcodebuild must succeed"
    plist = built_plist(derived)
    refute_nil plist, "built Morsel.app/Info.plist not found"

    assert_equal FIXTURE_URL, plist_value(plist, "MorselSupabaseURL")
    assert_equal FIXTURE_ANON_KEY, plist_value(plist, "MorselSupabaseAnonKey")
    assert_equal "#{FIXTURE_URL}/functions/v1/mcp", plist_value(plist, "MORSEL_MCP_URL")
  ensure
    FileUtils.remove_entry(derived) if derived && File.exist?(derived)
  end

  def test_built_plist_keeps_allowlisted_control_and_build_version
    skip "xcodebuild not available" unless xcodebuild_available?

    status, derived = build_morsel(extra_xcargs: ["INFOPLIST_KEY_NSCameraUsageDescription=#{CONTROL}"])
    assert status.success?, "unsigned xcodebuild must succeed"
    plist = built_plist(derived)
    refute_nil plist, "built Morsel.app/Info.plist not found"

    # The in-band allowlisted control still overrides through the template,
    # and CURRENT_PROJECT_VERSION still flows into CFBundleVersion.
    assert_equal CONTROL, plist_value(plist, "NSCameraUsageDescription")
    assert_equal FIXTURE_BUILD.to_s, plist_value(plist, "CFBundleVersion")
  ensure
    FileUtils.remove_entry(derived) if derived && File.exist?(derived)
  end

  def test_old_infoplist_key_mechanism_is_dropped_by_xcode
    # Documents WHY the template route exists: INFOPLIST_KEY_<custom> build
    # settings are silently omitted from the generated plist. If a future
    # change reintroduces that delivery, this test proves it cannot work.
    skip "xcodebuild not available" unless xcodebuild_available?

    derived = Dir.mktmpdir("morsel-old-mech")
    repo_root = File.expand_path("..", __dir__)
    cmd = [
      "xcodebuild", "-project", "app/Morsel.xcodeproj", "-scheme", "Morsel",
      "-configuration", "Release", "-sdk", "iphoneos",
      "-destination", "generic/platform=iOS",
      "-derivedDataPath", derived,
      "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
      "CODE_SIGN_IDENTITY=",
      "CURRENT_PROJECT_VERSION=#{FIXTURE_BUILD}",
      "INFOPLIST_KEY_MorselSupabaseURL=#{FIXTURE_URL}",
      "INFOPLIST_KEY_MorselSupabaseAnonKey=#{FIXTURE_ANON_KEY}",
      "INFOPLIST_KEY_MORSEL_MCP_URL=#{FIXTURE_URL}/functions/v1/mcp",
      "build"
    ]
    _out, status = Open3.capture2e(*cmd, chdir: repo_root)
    assert status.success?, "unsigned xcodebuild must succeed"
    plist = built_plist(derived)
    refute_nil plist, "built Morsel.app/Info.plist not found"
    assert_nil plist_value(plist, "MorselSupabaseURL"),
      "INFOPLIST_KEY_<custom> must not be delivered (Xcode allowlist)"
  ensure
    FileUtils.remove_entry(derived) if derived && File.exist?(derived)
  end
end
