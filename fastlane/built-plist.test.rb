# frozen_string_literal: true

# REQUIRED BUILT-ARTIFACT GATE for issue #32 (r2): proves the three Morsel
# runtime keys land in the BUILT Morsel.app/Info.plist through the real
# no-log delivery (the Fastfile populates the target-scoped Info.plist
# template FILE, never a command line), and that the explicit target-scoped
# INFOPLIST_FILE no longer contaminates SPM resource bundles. MORSEL_MCP_URL
# is the canonical Fly transport constant (issue #75) rather than a
# SUPABASE_URL-derived Edge Function URL.
#
# Asserts:
#   - every Info.plist under Morsel.app is enumerated;
#   - the top-level app plist differs from a baseline build ONLY by the three
#     Morsel runtime keys (plus test-controlled dynamic values);
#   - swift-crypto_Crypto.bundle/Info.plist is semantically identical to
#     baseline and carries no Morsel keys, app icons, purpose strings, or
#     scene metadata;
#   - no fixture value appears in captured xcodebuild command output;
#   - a forced build failure still restores the committed no-value template.
#
# No secrets: fixture values only. Skips cleanly when xcodebuild is absent.
#
# Run: mise exec ruby@4.0.5 -- ruby fastlane/built-plist.test.rb

require "minitest/autorun"
require "shellwords"
require "tmpdir"
require "open3"
require "json"
require "fileutils"

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
# Canonical MCP transport (issue #75; origin = the morselfood.app custom
# domain since #130): what the build must publish in
# MORSEL_MCP_URL regardless of the SUPABASE_URL fixture above. The legacy
# morsel-mcp.fly.dev origin still serves identically during the transition.
CANONICAL_MCP_URL = "https://mcp.morselfood.app/mcp"
CONTROL = "FIXTUREPROBE"
# Keys Xcode derives from the build machine/SDK; allowed to differ between
# runs of the same unsigned build and ignored in semantic comparisons.
DYNAMIC_KEYS = %w[
  BuildMachineOSBuild DTCompiler DTPlatformBuild DTPlatformName DTPlatformVersion
  DTSDKBuild DTSDKName DTXcode DTXcodeBuild
].freeze
MORSEL_KEYS = %w[MorselSupabaseURL MorselSupabaseAnonKey MORSEL_MCP_URL].freeze

class BuiltPlistTest < Minitest::Test
  def setup
    ENV["SUPABASE_URL"] = FIXTURE_URL
    ENV["SUPABASE_ANON_KEY"] = FIXTURE_ANON_KEY
  end

  def teardown
    ENV.delete("SUPABASE_URL")
    ENV.delete("SUPABASE_ANON_KEY")
    # The committed template must never be left value-bearing.
    committed = File.read(File.join(repo_root, "fastlane", "Morsel-Info.plist"))
    File.write(File.expand_path("Morsel-Info.plist", __dir__), committed)
  end

  def repo_root
    @repo_root ||= File.expand_path("..", __dir__)
  end

  def xcodebuild_available?
    return false unless RbConfig::CONFIG["host_os"] =~ /darwin/i

    _out, status = Open3.capture2e("xcodebuild", "-version")
    status.success?
  end

  def xcodebuild_cmd(derived, extra: [])
    [
      "xcodebuild", "-project", "app/Morsel.xcodeproj", "-scheme", "Morsel",
      "-configuration", "Release", "-sdk", "iphoneos",
      "-destination", "generic/platform=iOS",
      "-derivedDataPath", derived,
      "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
      "CODE_SIGN_IDENTITY=",
      "CURRENT_PROJECT_VERSION=#{FIXTURE_BUILD}",
      *extra, "build"
    ]
  end

  # Build with the REAL production delivery: the Fastfile populates the
  # target-scoped template file with fixture values for the duration of the
  # build, then restores it. Returns [status, derived, captured_output].
  def build_with_lane_delivery(extra: [])
    derived = Dir.mktmpdir("morsel-lane-delivery")
    output = nil
    status = nil
    with_morsel_supabase_plist do
      output, status = Open3.capture2e(*xcodebuild_cmd(derived, extra: extra),
        chdir: repo_root)
    end
    [status, derived, output]
  end

  # Baseline build: same unsigned build with the committed template untouched
  # (placeholders expand to empty strings) and no Supabase values anywhere.
  def build_baseline(extra: [])
    derived = Dir.mktmpdir("morsel-baseline")
    output, status = Open3.capture2e(*xcodebuild_cmd(derived, extra: extra),
      chdir: repo_root)
    [status, derived, output]
  end

  def app_plist(derived)
    Dir[File.join(derived, "Build/Products/Release-iphoneos/Morsel.app/Info.plist")].first
  end

  def all_plists(derived)
    app_dir = File.join(derived, "Build/Products/Release-iphoneos/Morsel.app")
    Dir[File.join(app_dir, "**", "Info.plist")].sort
  end

  def plist_hash(plist)
    out, status = Open3.capture2e("plutil", "-convert", "json", "-o", "-", plist)
    raise "plutil failed for #{plist}" unless status.success?

    JSON.parse(out)
  end

  def without_dynamic(hash)
    hash.reject { |k, _| DYNAMIC_KEYS.include?(k) }
  end

  def plist_value(plist, key)
    out, status = Open3.capture2e("/usr/libexec/PlistBuddy", "-c", "Print :#{key}", plist)
    return nil unless status.success?

    out.strip
  end

  def test_built_plist_contains_all_three_fixture_keys_via_lane_delivery
    skip "xcodebuild not available" unless xcodebuild_available?

    status, derived, output = build_with_lane_delivery
    assert status.success?, "unsigned xcodebuild must succeed"
    plist = app_plist(derived)
    refute_nil plist, "built Morsel.app/Info.plist not found"

    assert_equal FIXTURE_URL, plist_value(plist, "MorselSupabaseURL")
    assert_equal FIXTURE_ANON_KEY, plist_value(plist, "MorselSupabaseAnonKey")
    assert_equal CANONICAL_MCP_URL, plist_value(plist, "MORSEL_MCP_URL")
  ensure
    FileUtils.remove_entry(derived) if derived && File.exist?(derived)
  end

  def test_no_fixture_value_appears_in_captured_command_output
    skip "xcodebuild not available" unless xcodebuild_available?

    status, derived, output = build_with_lane_delivery
    assert status.success?, "unsigned xcodebuild must succeed"
    refute_includes output, FIXTURE_ANON_KEY,
      "fixture anon key must never appear in xcodebuild output"
    refute_includes output, FIXTURE_URL,
      "fixture URL must never appear in xcodebuild output"
    refute_includes output, CANONICAL_MCP_URL,
      "MCP URL must never appear in xcodebuild output"
  ensure
    FileUtils.remove_entry(derived) if derived && File.exist?(derived)
  end

  def test_nested_bundle_plist_is_clean_and_baseline_identical
    skip "xcodebuild not available" unless xcodebuild_available?

    status, derived, = build_with_lane_delivery
    assert status.success?, "unsigned xcodebuild must succeed"
    plists = all_plists(derived)
    assert plists.length >= 2,
      "expected top-level + nested bundle plists, found: #{plists.inspect}"

    plists.each do |plist|
      next if plist == app_plist(derived)

      keys = plist_hash(plist).keys
      (MORSEL_KEYS + %w[NSCameraUsageDescription NSHealthShareUsageDescription
        NSHealthUpdateUsageDescription NSPhotoLibraryUsageDescription
        CFBundleIcons UIApplicationSceneManifest UILaunchScreen]).each do |forbidden|
        refute_includes keys, forbidden,
          "#{forbidden} must not leak into nested plist #{plist}"
      end
    end
  ensure
    FileUtils.remove_entry(derived) if derived && File.exist?(derived)
  end

  def test_top_level_plist_differs_from_baseline_only_by_morsel_keys
    skip "xcodebuild not available" unless xcodebuild_available?

    status, derived_lane, = build_with_lane_delivery
    assert status.success?, "lane delivery build must succeed"
    status_b, derived_base, = build_baseline
    assert status_b.success?, "baseline build must succeed"

    lane_hash = without_dynamic(plist_hash(app_plist(derived_lane)))
    base_hash = without_dynamic(plist_hash(app_plist(derived_base)))

    assert_equal base_hash.keys.sort, lane_hash.keys.sort,
      "top-level key set must not change"
    differing = base_hash.keys.reject { |k| base_hash[k] == lane_hash[k] }
    assert_equal MORSEL_KEYS.sort, differing.sort,
      "top-level plist must differ from baseline ONLY by the three Morsel keys"
    # Baseline has empty strings; lane delivery has the fixture values.
    assert_equal "", base_hash["MorselSupabaseURL"]
    assert_equal FIXTURE_URL, lane_hash["MorselSupabaseURL"]
    assert_equal "", base_hash["MorselSupabaseAnonKey"]
    assert_equal FIXTURE_ANON_KEY, lane_hash["MorselSupabaseAnonKey"]
    assert_equal "", base_hash["MORSEL_MCP_URL"]
    assert_equal CANONICAL_MCP_URL, lane_hash["MORSEL_MCP_URL"]
  ensure
    FileUtils.remove_entry(derived_lane) if derived_lane && File.exist?(derived_lane)
    FileUtils.remove_entry(derived_base) if derived_base && File.exist?(derived_base)
  end

  def test_allowlisted_control_and_build_version_still_work
    skip "xcodebuild not available" unless xcodebuild_available?

    status, derived, = build_with_lane_delivery(
      extra: ["INFOPLIST_KEY_NSCameraUsageDescription=#{CONTROL}"]
    )
    assert status.success?, "unsigned xcodebuild must succeed"
    plist = app_plist(derived)
    assert_equal CONTROL, plist_value(plist, "NSCameraUsageDescription")
    assert_equal FIXTURE_BUILD.to_s, plist_value(plist, "CFBundleVersion")
  ensure
    FileUtils.remove_entry(derived) if derived && File.exist?(derived)
  end

  def test_forced_build_failure_restores_committed_template
    skip "xcodebuild not available" unless xcodebuild_available?

    template_path = File.expand_path("Morsel-Info.plist", __dir__)
    committed = File.read(template_path)
    refute_includes committed, FIXTURE_ANON_KEY

    derived = Dir.mktmpdir("morsel-forced-failure")
    # Force a fast xcodebuild failure with a bogus destination.
    cmd = xcodebuild_cmd(derived, extra: ["-destination", "platform=NotARealOS"])
    status = nil
    with_morsel_supabase_plist do
      _out, status = Open3.capture2e(*cmd, chdir: repo_root)
    end
    refute status.success?, "forced failure must actually fail"
    assert_equal committed, File.read(template_path),
      "committed no-value template must be restored after build failure"
    refute_includes File.read(template_path), FIXTURE_ANON_KEY
  ensure
    FileUtils.remove_entry(derived) if derived && File.exist?(derived)
  end

  def test_old_global_infoplist_file_mechanism_is_contamination_source
    # Documents WHY the target-scoped INFOPLIST_FILE exists: a command-line
    # INFOPLIST_FILE applies to EVERY target (including SPM resource bundles),
    # so the Morsel template leaks into swift-crypto_Crypto.bundle.
    skip "xcodebuild not available" unless xcodebuild_available?

    derived = Dir.mktmpdir("morsel-global-mech")
    template_path = File.expand_path("Morsel-Info.plist", __dir__)
    cmd = xcodebuild_cmd(derived, extra: ["INFOPLIST_FILE=#{template_path}"])
    _out, status = Open3.capture2e(*cmd, chdir: repo_root)
    assert status.success?, "unsigned xcodebuild must succeed"
    bundle_plist = Dir[File.join(derived,
      "Build/Products/Release-iphoneos/Morsel.app/*.bundle/Info.plist")].first
    refute_nil bundle_plist, "swift-crypto bundle plist must exist"
    keys = plist_hash(bundle_plist).keys
    (MORSEL_KEYS + %w[NSCameraUsageDescription CFBundleIcons UIApplicationSceneManifest])
      .each do |leaked|
      assert_includes keys, leaked,
        "expected command-line INFOPLIST_FILE to leak #{leaked} (r1 regression)"
    end
  ensure
    FileUtils.remove_entry(derived) if derived && File.exist?(derived)
  end
end
