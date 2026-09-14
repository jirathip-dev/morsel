import XCTest
@testable import Morsel

// Issue #188 — the revalidation-epoch registry that names a stored photo's
// revision: stable until a signal, scoped to the object/account a signal can
// name, bounded in size, and forgetting-safe (a forgotten object re-observes at
// epoch 0 — a NEW revision and therefore a refetch, never a stale serve).

final class MealPhotoRevisionsTests: XCTestCase {
    private let account = UUID()
    private let otherAccount = UUID()
    private let path = "5B1F0C2A-1111-4000-8000-000000000001/5B1F0C2A-1111-4000-8000-000000000002.jpg"
    private let otherPath = "5B1F0C2A-1111-4000-8000-000000000001/5B1F0C2A-1111-4000-8000-000000000003.jpg"

    func testEpochIsStableUntilAReplacementBumpsTheNamedObject() {
        let revisions = MealPhotoRevisions()
        XCTAssertEqual(revisions.observe(accountID: account, objectPath: path), 0)
        XCTAssertEqual(
            revisions.observe(accountID: account, objectPath: path), 0,
            "asking twice must not move the epoch (a warm read stays warm)"
        )

        revisions.replaced(accountID: account, objectPath: path)
        XCTAssertEqual(revisions.observe(accountID: account, objectPath: path), 1)
        XCTAssertEqual(
            revisions.observe(accountID: account, objectPath: otherPath), 0,
            "another object of the same account is untouched by a path-scoped signal"
        )
        XCTAssertEqual(revisions.observe(accountID: otherAccount, objectPath: path), 0)
        XCTAssertEqual(revisions.trackedCount(accountID: account), 2)
    }

    func testAccountReplacementBumpsEveryTrackedObjectOfThatAccountOnly() {
        let revisions = MealPhotoRevisions()
        _ = revisions.observe(accountID: account, objectPath: path)
        _ = revisions.observe(accountID: account, objectPath: otherPath)
        _ = revisions.observe(accountID: otherAccount, objectPath: path)

        revisions.replacedAccount(accountID: account)
        XCTAssertEqual(revisions.observe(accountID: account, objectPath: path), 1)
        XCTAssertEqual(revisions.observe(accountID: account, objectPath: otherPath), 1)
        XCTAssertEqual(
            revisions.observe(accountID: otherAccount, objectPath: path), 0,
            "another account's objects are never bumped"
        )
    }

    func testLogoutForgetsOnlyThatAccountsEpochs() {
        let revisions = MealPhotoRevisions()
        _ = revisions.observe(accountID: account, objectPath: path)
        _ = revisions.observe(accountID: otherAccount, objectPath: path)
        revisions.replaced(accountID: account, objectPath: path)

        revisions.removeAll(accountID: account)
        XCTAssertEqual(revisions.trackedCount(accountID: account), 0)
        XCTAssertEqual(revisions.trackedCount(accountID: otherAccount), 1)
        XCTAssertEqual(
            revisions.observe(accountID: otherAccount, objectPath: path), 0,
            "the other account's objects were never tracked with an epoch"
        )
    }

    func testTrackingIsBoundedAndAForgottenObjectReObservesFromZero() {
        let revisions = MealPhotoRevisions()
        _ = revisions.observe(accountID: account, objectPath: path)
        revisions.replaced(accountID: account, objectPath: path)
        XCTAssertEqual(revisions.observe(accountID: account, objectPath: path), 1)

        for index in 0..<(MealPhotoRevisions.maxTrackedObjects + 8) {
            _ = revisions.observe(accountID: account, objectPath: "5B1F0C2A-1111-4000-8000-00000000000\(index).jpg")
        }
        XCTAssertLessThanOrEqual(
            revisions.totalTrackedCount(), MealPhotoRevisions.maxTrackedObjects,
            "the registry holds a declared bound"
        )
        XCTAssertEqual(
            revisions.observe(accountID: account, objectPath: path), 0,
            "a forgotten object re-observes at 0 — a new revision, never a stale claim"
        )
    }
}
