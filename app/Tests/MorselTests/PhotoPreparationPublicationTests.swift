import XCTest
@testable import Morsel

/// Issue #187 — the publication gate both photo surfaces share.
///
/// Add Meal and the Edit-item sheet stamp every preparation and settle it
/// through `MealPhotoPreparationGate` / `MealPhotoPreparationGate.apply`, so
/// these tests pin the rule the surfaces rely on: a newer pick, Remove, or
/// leaving the route retires an in-flight preparation (its late result OR
/// error publishes nothing), while a failure that is still current reports its
/// message and leaves the previous photo (or draft) exactly as it was.
final class PhotoPreparationPublicationTests: XCTestCase {
    private let prepared = FoodImageUpload(data: Data([0x01, 0x02]), mimeType: "image/jpeg")
    private let newer = FoodImageUpload(data: Data([0x03, 0x04]), mimeType: "image/jpeg")

    func testANewerPickRetiresTheOlderPreparationResultAndError() {
        var gate = MealPhotoPreparationGate()
        let first = gate.begin()
        let second = gate.begin()

        XCTAssertEqual(gate.settle(.success(prepared), for: first), .discard)
        XCTAssertEqual(gate.settle(.failure(FoodImageError.invalidImage), for: first), .discard)
        XCTAssertEqual(gate.settle(.success(newer), for: second), .publish(newer))
    }

    func testRemoveAndLeavingTheRouteRetireTheInFlightPreparation() {
        var gate = MealPhotoPreparationGate()
        let stamp = gate.begin()
        gate.invalidate()

        XCTAssertFalse(gate.isCurrent(stamp))
        XCTAssertEqual(gate.settle(.success(prepared), for: stamp), .discard)
        XCTAssertEqual(gate.settle(.failure(FoodImageError.compressionFailed), for: stamp), .discard)
    }

    func testAFailureReportsTheMessageAndPreservesThePreviousPhoto() {
        var gate = MealPhotoPreparationGate()
        let stamp = gate.begin()
        var photo: FoodImageUpload? = prepared
        var message: String?

        MealPhotoPreparationGate.apply(
            gate.settle(.failure(FoodImageError.compressionFailed), for: stamp),
            photo: &photo,
            message: &message
        )
        XCTAssertEqual(photo, prepared, "a processing failure must keep the previous photo")
        XCTAssertEqual(
            message,
            DashboardUserMessage.userMessage(for: FoodImageError.compressionFailed),
            "a failure that is still current reports the shipped error line"
        )

        MealPhotoPreparationGate.apply(
            gate.settle(.success(newer), for: stamp),
            photo: &photo,
            message: &message
        )
        XCTAssertEqual(photo, newer)
    }

    func testARetiredStampChangesNothingAtAll() {
        var gate = MealPhotoPreparationGate()
        let stamp = gate.begin()
        var photo: FoodImageUpload? = prepared
        var message: String? = "previous error"

        gate.invalidate()
        MealPhotoPreparationGate.apply(
            gate.settle(.success(newer), for: stamp),
            photo: &photo,
            message: &message
        )

        XCTAssertEqual(photo, prepared, "a retired preparation must publish neither its result nor its error")
        XCTAssertEqual(message, "previous error")
    }
}
