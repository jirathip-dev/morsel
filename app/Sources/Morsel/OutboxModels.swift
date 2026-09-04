import Foundation

// Issue #106 — durable local-first meal outbox models. A meal save is
// committed to the account-scoped SQLite store as ONE row (meal + items JSON
// + photo BLOB) before any network work; the row carries the client-generated
// meal identity that the server accepts as its primary key, so retries can
// never duplicate a committed meal (server-side conflict guard, migration
// 0010). Rows stay queued across relaunch until the authoritative server
// result is read back; permanent refusals surface a friendly needs-attention
// state that preserves the recoverable payload.

/// User-visible sync state of a meal row (issue #106). `synced` rows come
/// from the authoritative remote snapshot; queued rows are painted from the
/// local store with an honest marker.
enum MealSyncState: String, Equatable, Sendable, Codable {
    case synced
    case pending
    case needsAttention = "needs_attention"

    /// Friendly, short copy for the journal row (never raw status text).
    var rowCopy: String? {
        switch self {
        case .synced: return nil
        case .pending: return "pending sync"
        case .needsAttention: return "needs attention"
        }
    }
}

/// Outbox row lifecycle (SQLite `meal_outbox.state`).
enum MealOutboxState: String, Equatable, Sendable {
    case pending
    case needsAttention = "needs_attention"
}

/// Coarse, persisted failure category for a queued meal. Categories drive
/// retry policy and friendly copy; raw Supabase/Postgres text is never
/// persisted or surfaced.
enum OutboxErrorCategory: String, Equatable, Sendable {
    case auth
    case validation
    case network
    case server
    case photo

    var friendlyDescription: String {
        switch self {
        case .auth:
            return "Your sign-in could not save this meal. Sign in again to retry."
        case .validation:
            return "This meal was refused. Keep it for later or remove it."
        case .network:
            return "Waiting for a connection to save this meal."
        case .server:
            return "Morsel could not save this meal right now. It is kept safely."
        case .photo:
            return "The photo could not be uploaded yet. It is kept safely."
        }
    }
}

/// One queued food item. Item identity is client-generated at enqueue so a
/// reloaded (relaunched) pending meal keeps stable item IDs.
struct QueuedMealItem: Codable, Equatable, Sendable {
    let itemID: UUID
    let name: String
    let quantity: Double
    let unit: String
    let caloriesKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let fiberG: Double?
    let sugarG: Double?
    let confidence: Double?
    let notes: String?

    init(_ draft: MealItemDraft, itemID: UUID = UUID()) {
        self.itemID = itemID
        name = draft.name
        quantity = draft.quantity
        unit = draft.unit.rawValue
        caloriesKcal = draft.caloriesKcal
        proteinG = draft.proteinG
        carbsG = draft.carbsG
        fatG = draft.fatG
        fiberG = draft.fiberG
        sugarG = draft.sugarG
        confidence = draft.confidence
        notes = draft.notes
    }

    init(
        itemID: UUID,
        name: String,
        quantity: Double,
        unit: String,
        caloriesKcal: Double?,
        proteinG: Double?,
        carbsG: Double?,
        fatG: Double?,
        fiberG: Double?,
        sugarG: Double?,
        confidence: Double?,
        notes: String?
    ) {
        self.itemID = itemID
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

    func item(source: MealSource) -> MealItem? {
        guard let parsedUnit = FoodUnit(rawValue: unit),
              quantity.isFinite, quantity > 0 else {
            return nil
        }
        return MealItem(
            itemID: itemID,
            name: name,
            quantity: quantity,
            unit: parsedUnit,
            caloriesKcal: caloriesKcal,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            fiberG: fiberG,
            sugarG: sugarG,
            confidence: confidence,
            notes: notes,
            source: source
        )
    }
}

/// Durable photo payload attached to a queued meal (stored as a BLOB in the
/// same transaction as the meal row — no orphaned file on a rejected meal).
struct QueuedMealPhoto: Equatable, Sendable {
    let data: Data
    let mimeType: String
}

/// One durable, account-scoped outbox row.
struct QueuedMeal: Equatable, Sendable {
    let mealID: UUID
    let mealType: MealType
    let eatenAt: Date
    let source: MealSource
    let notes: String?
    let items: [QueuedMealItem]
    let photo: QueuedMealPhoto?
    let state: MealOutboxState
    let attempts: Int
    let lastError: String?
    let lastErrorCategory: OutboxErrorCategory?
    /// Remote storage path once the photo upload succeeded (retries reuse it).
    let imagePath: String?
    let createdAt: Date
    let updatedAt: Date

    var syncState: MealSyncState {
        switch state {
        case .pending: return .pending
        case .needsAttention: return .needsAttention
        }
    }

    /// The journal-visible record for a queued meal (merged into snapshots
    /// until the authoritative remote row replaces it).
    var mealRecord: MealRecord {
        MealRecord(
            mealLogID: mealID,
            mealType: mealType,
            eatenAt: eatenAt,
            source: source,
            imagePath: imagePath,
            items: items.compactMap { $0.item(source: source) },
            syncState: syncState
        )
    }

    var draft: MealDraft {
        MealDraft(
            mealType: mealType,
            eatenAt: eatenAt,
            notes: notes,
            items: items.map { item in
                MealItemDraft(
                    name: item.name,
                    quantity: item.quantity,
                    unit: FoodUnit(rawValue: item.unit) ?? .serving,
                    caloriesKcal: item.caloriesKcal,
                    proteinG: item.proteinG,
                    carbsG: item.carbsG,
                    fatG: item.fatG,
                    fiberG: item.fiberG,
                    sugarG: item.sugarG,
                    confidence: item.confidence,
                    notes: item.notes
                )
            }
        )
    }
}

/// Builds the durable outbox payload for a validated draft. The meal row
/// identity is the client-generated idempotency key: the same UUID is sent to
/// the server as the meal_logs primary key, so a retried delivery can never
/// create a duplicate meal.
struct QueuedMealFactory {
    static func make(
        draft: MealDraft,
        photo: FoodImageUpload?,
        mealID: UUID = UUID(),
        now: Date = Date()
    ) -> QueuedMeal {
        QueuedMeal(
            mealID: mealID,
            mealType: draft.mealType,
            eatenAt: draft.eatenAt,
            source: photo == nil ? .manual : .photoVision,
            notes: draft.notes,
            items: draft.items.map { QueuedMealItem($0) },
            photo: photo.map { QueuedMealPhoto(data: $0.data, mimeType: $0.mimeType) },
            state: .pending,
            attempts: 0,
            lastError: nil,
            lastErrorCategory: nil,
            imagePath: nil,
            createdAt: now,
            updatedAt: now
        )
    }
}
