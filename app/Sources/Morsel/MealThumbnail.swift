import Combine
import Foundation
import SwiftUI
import UIKit

enum ThumbnailState: Equatable {
    case idle
    case loading
    case loaded(Data)
    case missing
}

@MainActor
final class MealThumbnailLoader: ObservableObject {
    @Published private(set) var state = ThumbnailState.idle

    private let repository: any DashboardRepository
    private let userID: UUID
    private let path: String

    init(repository: any DashboardRepository, userID: UUID, path: String) {
        self.repository = repository
        self.userID = userID
        self.path = path
    }

    func load() async {
        state = .loading
        do {
            let data = try await repository.loadMealImage(userID: userID, path: path)
            state = data.isEmpty ? .missing : .loaded(data)
        } catch is CancellationError {
            return
        } catch {
            state = .missing
        }
    }
}

struct MealThumbnailView: View {
    let repository: any DashboardRepository
    let userID: UUID
    let path: String

    @StateObject private var loader: MealThumbnailLoader

    init(repository: any DashboardRepository, userID: UUID, path: String) {
        self.repository = repository
        self.userID = userID
        self.path = path
        _loader = StateObject(
            wrappedValue: MealThumbnailLoader(repository: repository, userID: userID, path: path)
        )
    }

    var body: some View {
        Group {
            switch loader.state {
            case .loaded(let data):
                if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder(systemName: "photo")
                }
            case .loading, .idle:
                ZStack {
                    placeholder(systemName: "photo")
                    ProgressView()
                        .tint(Color.morselAccent)
                }
            case .missing:
                placeholder(systemName: "photo")
            }
        }
        .frame(width: 56, height: 56)
        .background(Color.morselSurfaceTwo)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Meal photo")
        .task(id: path) {
            await loader.load()
        }
    }

    private func placeholder(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(Color.morselInkThree)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
