import Foundation
import UIKit
import XCTest
@testable import Morsel

final class MealCaptureTests: XCTestCase {
    func testFoodImagePathUsesOwnUserAndJPGObjectName() {
        let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")
            ?? UUID()
        let imageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")
            ?? UUID()

        XCTAssertEqual(
            FoodImageStore.bucketPath(userID: userID, imageID: imageID),
            "food-images/\(userID.uuidString)/\(imageID.uuidString).jpg"
        )
        XCTAssertEqual(
            FoodImageStore.objectPath(userID: userID, imageID: imageID),
            "\(userID.uuidString)/\(imageID.uuidString).jpg"
        )
    }

    @MainActor
    func testMockRejectsCrossUserImagePathBeforeUpload() async throws {
        let repository = MockDashboardRepository(snapshot: emptySnapshot())
        let ownerID = UUID()
        let otherUserPath = FoodImageStore.bucketPath(userID: UUID(), imageID: UUID())
        let upload = FoodImageUpload(data: Data([0x01]), mimeType: "image/jpeg")

        do {
            _ = try await repository.uploadImage(
                userID: ownerID,
                path: otherUserPath,
                upload: upload
            )
            XCTFail("A cross-user storage path must be rejected.")
        } catch let error as FoodImageError {
            XCTAssertEqual(error, .invalidPath)
        }
        XCTAssertTrue(repository.uploadedImagePaths.isEmpty)
    }

    @MainActor
    func testMockRejectsOversizedImageBeforeUpload() async throws {
        let repository = MockDashboardRepository(snapshot: emptySnapshot())
        let userID = UUID()
        let path = FoodImageStore.bucketPath(userID: userID, imageID: UUID())
        let upload = FoodImageUpload(
            data: Data(repeating: 0, count: FoodImageStore.maxBytes + 1),
            mimeType: "image/jpeg"
        )

        do {
            _ = try await repository.uploadImage(userID: userID, path: path, upload: upload)
            XCTFail("An image over the bucket limit must be rejected.")
        } catch let error as FoodImageError {
            XCTAssertEqual(error, .tooLarge)
        }
        XCTAssertTrue(repository.uploadedImagePaths.isEmpty)
    }

    @MainActor
    func testMockRejectsNonImageBeforeUpload() async throws {
        let repository = MockDashboardRepository(snapshot: emptySnapshot())
        let userID = UUID()
        let path = FoodImageStore.bucketPath(userID: userID, imageID: UUID())
        let upload = FoodImageUpload(data: Data([0x01]), mimeType: "text/plain")

        do {
            _ = try await repository.uploadImage(userID: userID, path: path, upload: upload)
            XCTFail("A non-image MIME type must be rejected.")
        } catch let error as FoodImageError {
            XCTAssertEqual(error, .unsupportedMimeType)
        }
        XCTAssertTrue(repository.uploadedImagePaths.isEmpty)
    }

    @MainActor
    func testMockRejectsUnsupportedImageSubtypeBeforeUpload() async throws {
        let repository = MockDashboardRepository(snapshot: emptySnapshot())
        let userID = UUID()
        let path = FoodImageStore.bucketPath(userID: userID, imageID: UUID())
        let upload = FoodImageUpload(data: Data([0x01]), mimeType: "image/gif")

        do {
            _ = try await repository.uploadImage(userID: userID, path: path, upload: upload)
            XCTFail("An image subtype outside the Storage allowlist must be rejected.")
        } catch let error as FoodImageError {
            XCTAssertEqual(error, .unsupportedMimeType)
        }
        XCTAssertTrue(repository.uploadedImagePaths.isEmpty)
    }

    func testCompressorProducesJPEGWellBelowBucketLimit() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let image = renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }

        let upload = try FoodImageCompressor.compress(image)

        XCTAssertEqual(upload.mimeType, "image/jpeg")
        XCTAssertLessThanOrEqual(upload.data.count, FoodImageStore.targetMaxBytes)
        XCTAssertLessThan(upload.data.count, FoodImageStore.maxBytes)
    }

    @MainActor
    func testAddingPhotoMealCreatesImagePathAndRefreshesTodayList() async throws {
        let repository = MockDashboardRepository(snapshot: emptySnapshot())
        let viewModel = DashboardViewModel(repository: repository, userID: UUID())
        let draft = mealDraft()
        let upload = FoodImageUpload(data: Data([0x01, 0x02]), mimeType: "image/jpeg")

        let didAdd = await viewModel.addMeal(draft: draft, photo: upload)
        XCTAssertTrue(didAdd)
        let meal = try XCTUnwrap(viewModel.snapshot?.meals.first)

        XCTAssertEqual(meal.imagePath, repository.uploadedImagePaths.first)
        XCTAssertTrue(meal.imagePath?.hasPrefix("food-images/\(viewModel.userID.uuidString)/") == true)
        XCTAssertEqual(meal.items.count, 1)
        XCTAssertEqual(viewModel.snapshot?.meals.count, 1)
    }

    @MainActor
    func testManualMealRemainsAvailableWithoutPhoto() async throws {
        let repository = MockDashboardRepository(snapshot: emptySnapshot())
        let viewModel = DashboardViewModel(repository: repository, userID: UUID())

        await viewModel.load()
        let didAdd = await viewModel.addMeal(draft: mealDraft(), photo: nil)
        let meal = try XCTUnwrap(viewModel.snapshot?.meals.first)

        XCTAssertTrue(didAdd)
        XCTAssertEqual(meal.source, .manual)
        XCTAssertNil(meal.imagePath)
        XCTAssertTrue(repository.uploadedImagePaths.isEmpty)
    }

    @MainActor
    func testFailedMealRPCLeavesMealAndItemsAbsent() async throws {
        let repository = MockDashboardRepository(snapshot: emptySnapshot())
        repository.failMealLog = true
        let viewModel = DashboardViewModel(repository: repository, userID: UUID())
        let upload = FoodImageUpload(data: Data([0x01]), mimeType: "image/jpeg")

        await viewModel.load()
        let didAdd = await viewModel.addMeal(draft: mealDraft(), photo: upload)
        XCTAssertFalse(didAdd)
        XCTAssertTrue(viewModel.snapshot?.meals.isEmpty == true)
        XCTAssertTrue(repository.uploadedImagePaths.isEmpty)
    }

    @MainActor
    func testThumbnailTransitionsFromLoadingToLoadedAndMissing() async throws {
        let repository = MockDashboardRepository(snapshot: emptySnapshot())
        let userID = UUID()
        let path = FoodImageStore.bucketPath(userID: userID, imageID: UUID())
        let data = Data([0x01, 0x02, 0x03])
        _ = try await repository.uploadImage(
            userID: userID,
            path: path,
            upload: FoodImageUpload(data: data, mimeType: "image/jpeg")
        )

        let loaded = MealThumbnailLoader(repository: repository, userID: userID, path: path)
        XCTAssertEqual(loaded.state, .idle)
        let loadTask = Task { await loaded.load() }
        try await Task.sleep(for: .milliseconds(1))
        XCTAssertTrue([.loading, .loaded(data)].contains(loaded.state))
        await loadTask.value
        XCTAssertEqual(loaded.state, .loaded(data))

        repository.removeImage(at: path)
        let missing = MealThumbnailLoader(repository: repository, userID: userID, path: path)
        await missing.load()
        XCTAssertEqual(missing.state, .missing)
    }

    private func emptySnapshot() -> DashboardSnapshot {
        DashboardSnapshot(date: Date(timeIntervalSince1970: 0), meals: [], goal: nil)
    }

    private func mealDraft() -> MealDraft {
        MealDraft(
            mealType: .lunch,
            eatenAt: Date(timeIntervalSince1970: 0),
            notes: nil,
            items: [
                MealItemDraft(
                    name: "Rice",
                    quantity: 1,
                    unit: .serving,
                    caloriesKcal: 220,
                    proteinG: 4,
                    carbsG: 48,
                    fatG: 1,
                    fiberG: nil,
                    sugarG: nil,
                    confidence: 1,
                    notes: nil
                )
            ]
        )
    }
}
