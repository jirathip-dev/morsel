import SwiftUI
import XCTest
@testable import Morsel

@MainActor
final class HeroDatedTargetTests: XCTestCase {
    func testPastUsesSavedCaloriesAndMacrosNotTodaysGoal() async throws {
        let snapshot = try HeroTargetFixture.snapshot(saved: true)
        for (theme, scheme) in HeroTargetFixture.themes {
            let image = try await HeroTargetFixture.capture(snapshot, scheme: scheme)
            let text = try WeightDeltaRendering.recognizedText(image)
            XCTAssertTrue(text.contains("2,520"), text)
            for target in ["140", "280", "90"] { XCTAssertTrue(text.contains(target), text) }
            XCTAssertFalse(text.contains("3,000"), text)
            XCTAssertFalse(text.lowercased().contains("unavailable"), text)
            HeroTargetFixture.attach(image, name: "286-\(theme)-past-saved", to: self)
            print("ISSUE286-SAVED \(theme): \(text.replacingOccurrences(of: "\n", with: " | "))")
        }
    }

    func testMissingOrUnattributableTargetIsExplicitAndNeverBorrows() async throws {
        for (theme, scheme) in HeroTargetFixture.themes {
            let snapshot = try HeroTargetFixture.snapshot(saved: false)
            let image = try await HeroTargetFixture.capture(snapshot, scheme: scheme)
            let text = try WeightDeltaRendering.recognizedText(image)
            XCTAssertTrue(text.lowercased().contains("target unavailable for this day"), text)
            XCTAssertFalse(text.contains("3,000"), text)
            XCTAssertFalse(text.contains("180"), text)
            HeroTargetFixture.attach(image, name: "286-\(theme)-past-unavailable", to: self)
        }
        let wrongDay = try HeroTargetFixture.target()
        XCTAssertNil(wrongDay.attributableGoal(on: HeroTargetFixture.today))
        XCTAssertNil(wrongDay.attributableGoal(on: HeroTargetFixture.past.addingTimeInterval(-86_400)))
    }

    func testTodayKeepsBaselineAndConfirmedDayOnlyAddition() async throws {
        let goal = HeroTargetFixture.currentGoal
        let fuel = TrainingFuelModel(now: { HeroTargetFixture.today })
        let snapshot = try HeroTargetFixture.snapshot(saved: true, today: true)
        fuel.synchronize(snapshot)
        XCTAssertEqual(fuel.target, goal.calorieTargetKcal)
        fuel.beginReview()
        fuel.draft = "200"
        fuel.acknowledgesDayOnly = true
        await fuel.confirm()
        XCTAssertEqual(fuel.target, 3_200)
        for (theme, scheme) in HeroTargetFixture.themes {
            let image = try await HeroTargetFixture.capture(snapshot, scheme: scheme, fuel: fuel)
            let text = try WeightDeltaRendering.recognizedText(image)
            XCTAssertTrue(text.contains("3,200"), text)
            XCTAssertTrue(text.contains("180") && text.contains("350") && text.contains("100"), text)
            XCTAssertFalse(text.contains("2,520"), text)
            HeroTargetFixture.attach(image, name: "286-\(theme)-today", to: self)
        }
        fuel.undo()
        XCTAssertEqual(fuel.target, 3_000)
        XCTAssertNil(fuel.addition)
    }

    func testProvenanceSurvivesSnapshotCacheAndLegacyNeverBecomesHistory() async throws {
        let snapshot = try HeroTargetFixture.snapshot(saved: true)
        let directory = URL(fileURLWithPath: "/tmp/morsel-286-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID()
        let database = LocalDataStore.storeURL(root: directory, accountID: account)
        let repository = LocalFirstDashboardRepository(remote: MockDashboardRepository(snapshot: snapshot),
            store: try LocalDataStore(databaseURL: database),
            snapshotCache: try LocalSnapshotCache(databaseURL: database))
        let merged = try await repository.loadToday(userID: account, date: snapshot.date)
        let cached = try await repository.cachedToday(userID: account, date: snapshot.date)
        XCTAssertEqual(merged.datedTarget, snapshot.datedTarget)
        XCTAssertEqual(cached?.datedTarget, snapshot.datedTarget)
        let bytes = try JSONEncoder().encode(snapshot.cachedCopy)
        let restored = try JSONDecoder().decode(DashboardSnapshot.self, from: bytes)
        XCTAssertEqual(restored.datedTarget, snapshot.datedTarget)
        XCTAssertEqual(restored.datedTarget?.attributableGoal(on: restored.date)?.calorieTargetKcal, 2_520)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        legacy.removeValue(forKey: "datedTarget")
        let old = try JSONDecoder().decode(DashboardSnapshot.self,
                                          from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.goal?.calorieTargetKcal, 3_000)
        XCTAssertNil(old.datedTarget)
    }
}

@MainActor
enum HeroTargetFixture {
    static let themes: [(String, ColorScheme)] = [("paper", .light), ("night", .dark)]
    static let past = Date(timeIntervalSince1970: 1_789_560_000)
    static let today = past.addingTimeInterval(86_400)
    static let currentGoal = DashboardGoal(calorieTargetKcal: 3_000, proteinG: 180, carbsG: 350,
                                          fatG: 100, source: .manual)

    static func target() throws -> DatedTarget {
        let calendar = Calendar.autoupdatingCurrent
        return DatedTarget(date: DatedTarget.label(past), timezone: calendar.timeZone.identifier,
            baseline: DatedBaseline(revisionID: "00000000-0000-4000-8000-000000000286",
                recordedAt: MorselDate.iso8601(past), effectiveDate: DatedTarget.label(past),
                timezone: calendar.timeZone.identifier, sourceVersion: "targets-v1",
                goal: DatedGoal(calorieTargetKcal: 2_400, proteinG: 140, carbsG: 280, fatG: 90, source: .manual),
                profileUpdatedAt: nil, goalsUpdatedAt: MorselDate.iso8601(past), weightMeasuredAt: nil),
            confirmedAdditionKcal: 120,
            additionRevision: DatedAdditionRevision(revisionID: "00000000-0000-4000-8000-000000002860",
                recordedAt: MorselDate.iso8601(past), timezone: calendar.timeZone.identifier,
                previousRevisionID: nil, historicalConfirmation: false, manualGoalAcknowledged: true),
            totalTargetKcal: 2_520)
    }

    static func snapshot(saved: Bool, today: Bool = false) throws -> DashboardSnapshot {
        let date = today ? Self.today : past
        let item = MealItem(itemID: UUID(), name: "Repro meal", quantity: 1, unit: .serving,
                            caloriesKcal: 1_953, proteinG: 124, carbsG: 162, fatG: 80,
                            fiberG: nil, sugarG: nil, confidence: nil, notes: "Synthetic owner-total reproduction")
        let meal = MealRecord(mealLogID: UUID(), mealType: .lunch, eatenAt: date, source: .manual, items: [item])
        return DashboardSnapshot(date: DashboardMath.startOfLocalDay(date), meals: [meal], goal: currentGoal,
                                 datedTarget: saved ? try target() : nil)
    }

    static func capture(_ snapshot: DashboardSnapshot, scheme: ColorScheme,
                        fuel: TrainingFuelModel? = nil) async throws -> UIImage {
        MorselFontCatalog.register()
        let model = DashboardViewModel(repository: MockDashboardRepository(snapshot: snapshot),
                                       userID: UUID(), dateProvider: { today })
        model.selectDate(snapshot.date)
        await model.load()
        let training = fuel ?? TrainingFuelModel(now: { today })
        if fuel == nil { training.synchronize(DashboardSnapshot(date: today, meals: [], goal: currentGoal)) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; window.rootViewController = nil }
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = UIHostingController(rootView:
            TodayView(viewModel: model, showSettings: {}, addMeal: {})
                .environmentObject(training).environment(\.trainingFuelHosted, true)
                .environment(\.locale, Locale(identifier: "en_US"))
                .preferredColorScheme(scheme))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    static func attach(_ image: UIImage, name: String, to test: XCTestCase) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }
}
