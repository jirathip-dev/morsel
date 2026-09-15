#!/usr/bin/env python3
"""Prepare an owned, disposable checkout; never edit the delivered app.

Prints its absolute path. Then run its DiaryCapture scheme on an admitted lane
simulator. The UI tests produce native XCUIScreen attachments. Mid-flip freezes
the real state machine at a drag progress, not an invented renderer.
"""
import io
import hashlib
import json
import pathlib
import shutil
import subprocess
import tarfile
import tempfile

root = pathlib.Path(__file__).resolve().parents[4]
tools = pathlib.Path(__file__).parent
scratch = pathlib.Path(tempfile.mkdtemp(prefix="morsel168-capture-"))
(scratch / ".issue168-owned").touch()
archive = subprocess.check_output(["git", "archive", "HEAD"], cwd=root)
with tarfile.open(fileobj=io.BytesIO(archive)) as source:
    source.extractall(scratch, filter="data")
changed = subprocess.check_output(["git", "ls-files", "-m", "-o", "--exclude-standard"], cwd=root, text=True)
for name in changed.splitlines():
    path = pathlib.Path(name)
    if name.startswith("app/") and (root / path).is_file():
        (scratch / path).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / path, scratch / path)


def replace(path, old, new):
    text = path.read_text()
    assert text.count(old) == 1, (path, old)
    path.write_text(text.replace(old, new))


source_hashes = {
    str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in sorted((root / "app/Sources/Morsel").glob("*.swift"))
}
(scratch / "source-manifest.json").write_text(json.dumps(source_hashes, indent=2) + "\n")
app = scratch / "app/Sources/Morsel/MorselApp.swift"
text = app.read_text()
start, end = text.index("@main"), text.index("struct MorselConfiguration")
fixture = (tools / "DiaryFixture.swift.fixture").read_text()
app.write_text(text[:start] + fixture + "\n" + text[end:])
replace(app, "let services = AccountReliabilityServices(client: supabaseClient, userID: session.userID)",
        "let services: AccountReliabilityServices? = nil")
replace(app, "let remote = SupabaseDashboardRepository(client: supabaseClient)", "let remote = DiaryCaptureRepository()")
replace(app, "repository: remote, userID: session.userID, weightImporter: importer))",
        "repository: remote, userID: session.userID, weightImporter: importer, "
        "dateProvider: { DiaryCaptureRepository.today }))")
replace(app, "repository: remote, userID: session.userID))\n        }\n        fallbackImporter",
        "repository: remote, userID: session.userID, today: DiaryCaptureRepository.today))\n"
        "        }\n        fallbackImporter")
replace(app, "if let timezoneSync { Task { await timezoneSync.syncIfChanged() } }",
        "viewModel.selectDate(DiaryCaptureRepository.selection)\n"
        "            if let timezoneSync { Task { await timezoneSync.syncIfChanged() } }")
replace(app, "if !OnboardingStore().hasCompleted(for: viewModel.userID)", "if false")
replace(app, "init() { MorselFontCatalog.register() }",
        "init() { MorselFontCatalog.register(); "
        "UserDefaults.standard.set(ProcessInfo.processInfo.environment[\"DIARY_THEME\"] == \"night\" ? "
        "\"nightInk\" : \"paper\", forKey: MorselAppearance.themePreferenceKey) }")
page = scratch / "app/Sources/Morsel/JournalDiaryPage.swift"
replace(page, ".task { await calendar.load() }", ".task { await calendar.load(); "
        "if DiaryCaptureRepository.mode == \"mid\" { "
        "try? await Task.sleep(for: .milliseconds(700)); "
        "machine.interrupt(); machine.selectionChanged(to: model.selectedDate); machine.interrupt(); "
        "machine.dragChanged(deltaX: 72, deltaY: 0, width: 120) } }")
replace(page, ".clipped()", ".clipped().accessibilityIdentifier(machine.phase == .dragging ? "
        "\"diary-mid-ready\" : \"diary-rest\")")
project = scratch / "app/project.yml"
replace(project, "schemes:\n", "  DiaryCaptureTests:\n    type: bundle.ui-testing\n    platform: iOS\n"
        "    deploymentTarget: \"17.0\"\n    sources: [CaptureUI]\n    dependencies:\n      - target: Morsel\n"
        "    settings:\n      base:\n        GENERATE_INFOPLIST_FILE: YES\n"
        "        PRODUCT_BUNDLE_IDENTIFIER: com.jirathip.morsel.diary-capture\nschemes:\n"
        "  DiaryCapture:\n    build:\n      targets:\n        Morsel: all\n        DiaryCaptureTests: [test]\n"
        "    test:\n      targets: [DiaryCaptureTests]\n")
(scratch / "app/CaptureUI").mkdir()
shutil.copyfile(tools / "DiaryCaptureUITests.swift.fixture", scratch / "app/CaptureUI/DiaryCaptureUITests.swift")
subprocess.run(["xcodegen", "generate"], cwd=scratch / "app", check=True)
print(scratch)
