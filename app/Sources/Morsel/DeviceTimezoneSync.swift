import Foundation
import Supabase

// Issue #121 — the device's IANA zone is mirrored into profiles.timezone
// when it CHANGES (checked on launch and on every foreground). Server-side
// zone-aware day math (MCP day tools + stored day rows) then uses the same
// day boundary the app displays. The write is one-way and best effort: the
// per-account marker only advances after a successful update, so a network
// blip simply retries at the next launch/foreground, and repeated
// foregrounds in the same zone never write twice.
final class DeviceTimezoneSync {
    private let client: SupabaseClient
    private let userID: UUID
    private let defaults: UserDefaults
    private let now: () -> Date

    init(
        client: SupabaseClient,
        userID: UUID,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() }
    ) {
        self.client = client
        self.userID = userID
        self.defaults = defaults
        self.now = now
    }

    /// IANA names the profiles.timezone DB constraint accepts: the fixed
    /// 'UTC' alias or an Area/Location name containing '/'. Anything else
    /// (e.g. 'GMT') would trip the CHECK and must never be sent.
    static func isWritableIANAZone(_ identifier: String) -> Bool {
        identifier == "UTC" || identifier.contains("/")
    }

    private var markerKey: String {
        "morsel.deviceTimezone.\(userID.uuidString)"
    }

    func syncIfChanged() async {
        let zone = TimeZone.autoupdatingCurrent.identifier
        guard Self.isWritableIANAZone(zone), zone != defaults.string(forKey: markerKey) else {
            return
        }
        do {
            let updated: [ZoneWriteResponse] = try await client
                .from("profiles")
                .update(["timezone": zone])
                .eq("user_id", value: userID.uuidString)
                .select("user_id")
                .execute()
                .value
            // Only advance the marker when a profile row actually matched:
            // a fresh account whose profile row does not exist yet must
            // retry once the row exists.
            if !updated.isEmpty {
                defaults.set(zone, forKey: markerKey)
            }
        } catch {
            // Best effort — the next launch/foreground retries.
        }
    }
}

private struct ZoneWriteResponse: Decodable {
    let userID: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
    }
}
