import Foundation
import SwiftUI
import UIKit

struct MealItemDraft: Equatable, Sendable {
    let name: String
    let quantity: Double
    let unit: FoodUnit
    let caloriesKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let fiberG: Double?
    let sugarG: Double?
    let confidence: Double?
    let notes: String?

    init(
        name: String,
        quantity: Double = 1,
        unit: FoodUnit = .serving,
        caloriesKcal: Double? = nil,
        proteinG: Double? = nil,
        carbsG: Double? = nil,
        fatG: Double? = nil,
        fiberG: Double? = nil,
        sugarG: Double? = nil,
        confidence: Double? = nil,
        notes: String? = nil
    ) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.caloriesKcal = caloriesKcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
        self.sugarG = sugarG
        self.confidence = confidence
        self.notes = notes
    }
}

struct MealDraft: Equatable, Sendable {
    let mealType: MealType
    let eatenAt: Date
    let notes: String?
    let items: [MealItemDraft]

    init(mealType: MealType, eatenAt: Date, notes: String? = nil, items: [MealItemDraft]) {
        self.mealType = mealType
        self.eatenAt = eatenAt
        self.notes = notes
        self.items = items
    }
}

struct FoodImageUpload: Equatable, Sendable {
    let data: Data
    let mimeType: String
}

enum FoodImageError: LocalizedError, Equatable {
    case unsupportedMimeType
    case tooLarge
    case invalidImage
    case compressionFailed
    case invalidPath

    var errorDescription: String? {
        switch self {
        case .unsupportedMimeType:
            return "Choose an image file for the meal photo."
        case .tooLarge:
            return "The meal photo must be smaller than 10 MiB."
        case .invalidImage:
            return "Morsel could not read that image. Choose another photo."
        case .compressionFailed:
            return "Morsel could not prepare that photo for upload."
        case .invalidPath:
            return "The meal photo path does not belong to this account."
        }
    }
}

enum FoodImageStore {
    static let bucket = "food-images"
    static let allowedMimeTypes: Set<String> = ["image/jpeg", "image/png", "image/webp"]
    static let maxBytes = 10 * 1024 * 1024
    static let targetMaxBytes = 5 * 1024 * 1024

    static func objectPath(userID: UUID, imageID: UUID) -> String {
        "\(userID.uuidString)/\(imageID.uuidString).jpg"
    }

    static func bucketPath(userID: UUID, imageID: UUID) -> String {
        "\(bucket)/\(objectPath(userID: userID, imageID: imageID))"
    }

    static func validate(data: Data, mimeType: String) throws {
        try validateMimeType(mimeType)
        guard data.count <= maxBytes else {
            throw FoodImageError.tooLarge
        }
    }

    static func validateMimeType(_ mimeType: String) throws {
        let normalized = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowedMimeTypes.contains(normalized) else {
            throw FoodImageError.unsupportedMimeType
        }
    }

    static func validateSourceMimeType(_ mimeType: String) throws {
        let normalized = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("image/"), normalized.count > "image/".count else {
            throw FoodImageError.unsupportedMimeType
        }
    }

    @discardableResult
    static func validate(bucketPath: String, for userID: UUID) throws -> String {
        let components = bucketPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 3,
              components[0] == Substring(bucket),
              let ownerID = UUID(uuidString: String(components[1])),
              ownerID == userID,
              components[2].hasSuffix(".jpg"),
              UUID(uuidString: String(components[2].dropLast(4))) != nil else {
            throw FoodImageError.invalidPath
        }
        return components.dropFirst().map(String.init).joined(separator: "/")
    }
}

enum FoodImageCompressor {
    static func prepare(data: Data, mimeType: String) throws -> FoodImageUpload {
        try FoodImageStore.validateSourceMimeType(mimeType)
        guard let image = UIImage(data: data) else {
            throw FoodImageError.invalidImage
        }
        return try compress(image)
    }

    static func compress(_ image: UIImage) throws -> FoodImageUpload {
        let sourceDimension = max(image.size.width, image.size.height)
        guard sourceDimension.isFinite, sourceDimension > 0 else {
            throw FoodImageError.invalidImage
        }

        var targetDimension = min(sourceDimension, 2_048)
        for _ in 0..<5 {
            guard let resized = resized(image, maxDimension: targetDimension) else {
                throw FoodImageError.compressionFailed
            }
            for quality in [0.8, 0.7, 0.6, 0.5, 0.4, 0.3] {
                guard let data = resized.jpegData(compressionQuality: quality) else {
                    continue
                }
                if data.count <= FoodImageStore.targetMaxBytes {
                    return FoodImageUpload(data: data, mimeType: "image/jpeg")
                }
            }
            targetDimension *= 0.75
        }
        throw FoodImageError.tooLarge
    }

    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let sourceDimension = max(image.size.width, image.size.height)
        guard sourceDimension.isFinite, sourceDimension > 0, maxDimension > 0 else {
            return nil
        }
        guard sourceDimension > maxDimension else {
            return image
        }
        let scale = maxDimension / sourceDimension
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

enum MealDraftValidation {
    static func validate(_ draft: MealDraft) throws {
        guard !draft.items.isEmpty else {
            throw MorselError.invalidInput("Add at least one food to the meal.")
        }
        for item in draft.items {
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.quantity.isFinite,
                  item.quantity > 0 else {
                throw MorselError.invalidInput("Each food needs a name and a positive quantity.")
            }
            try validate(item.caloriesKcal, field: "calories")
            try validate(item.proteinG, field: "protein")
            try validate(item.carbsG, field: "carbs")
            try validate(item.fatG, field: "fat")
            try validate(item.fiberG, field: "fiber")
            try validate(item.sugarG, field: "sugar")
            if let confidence = item.confidence,
               !confidence.isFinite || !(0...1).contains(confidence) {
                throw MorselError.invalidInput("Confidence must be between 0 and 1.")
            }
        }
    }

    private static func validate(_ value: Double?, field: String) throws {
        guard let value else {
            return
        }
        guard value.isFinite, value >= 0 else {
            throw MorselError.invalidInput("\(field.capitalized) must be zero or greater.")
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {
        _ = picker
        _ = context
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            } else {
                parent.onCancel()
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
            picker.dismiss(animated: true)
        }
    }
}
