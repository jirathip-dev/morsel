import Foundation

// Issue #106 — calm Apple Health sync status (never raw entitlement/HK
// text). Issue #112 makes the claim per-type truthful: `synced` names ONLY
// the kinds that uploaded ≥1 row in the last successful pass; a still-open
// read prompt is `permissionRequired`; a decided read with no body-mass rows
// anywhere is the calm `noWeightData` state. `pending` means locally stored
// rows are waiting for a connection.
enum HealthSyncedKind: Hashable, Sendable {
    case bodyMass
    case activeEnergy

    var name: String {
        switch self {
        case .bodyMass: return "weight"
        case .activeEnergy: return "energy"
        }
    }
}

enum HealthCalmStatus: Equatable, Sendable {
    case unknown
    case syncing
    case synced(Date, syncedKinds: Set<HealthSyncedKind>)
    case pending
    case permissionRequired
    case noWeightData
    case unavailable

    var copy: String {
        switch self {
        case .unknown:
            return "Apple Health sync has not run yet."
        case .syncing:
            return "Checking Apple Health…"
        case let .synced(date, kinds):
            var text = "Last successful Health sync · \(date.formatted(date: .omitted, time: .shortened))"
            let names: [String]
            if kinds.contains(.bodyMass) && kinds.contains(.activeEnergy) {
                names = [HealthSyncedKind.bodyMass.name, HealthSyncedKind.activeEnergy.name]
            } else {
                names = kinds.map(\.name)
            }
            switch names.count {
            case 2:
                text += " · \(names.joined(separator: " and "))"
            case 1:
                text += " · \(names[0]) only"
            default:
                break
            }
            return text
        case .pending:
            return "Health data is ready — it will sync when a connection is available."
        case .permissionRequired:
            return "Health read access not granted — allow Apple Health access in "
                + "Settings › Health › Data Access & Devices › Morsel"
        case .noWeightData:
            return "No weight data in the last 30 days"
        case .unavailable:
            return "Apple Health is unavailable on this device."
        }
    }
}
