import Foundation
import Supabase

// Issue #194 — deterministic bounded paging/chunking at the collection read
// seams. The app used to ask each collection for "everything" in one request:
// a deployment row cap (Supabase's `db-max-rows`, default 1000)
// silently truncated the response, and a dense day's meal/menu ids went out in
// one `in.(...)` request that a gateway can reject for URL length.
//
// Every read here is a snapshot over a stable TOTAL order:
//
// - Order: `eaten_at,id`, `created_at,id`, `measured_at,kg`, `name,id` and
//   `menu_id,id`. A page boundary therefore always falls between rows whose
//   order is total — no row is skipped and none is delivered twice because of
//   an unstable sort, equal timestamps included.
// - Bounds: `BoundedRead.pageSize` rows per page, `BoundedRead.idChunkSize`
//   ids per `in.(...)` request, and chunks fetched one at a time
//   (`maxConcurrentChunks`), so a dense collection cannot fan out into a
//   request storm; the read graph's own ceiling stays
//   `ReadGraph.maxInFlightRequests`.
// - Caps: when a deployment clamps a response below the requested page size,
//   the REST layer reports the covered span in `Content-Range`; the read adopts
//   that smaller page size and keeps paging, so a clamped deployment still
//   returns the COMPLETE collection instead of a silent prefix. A short page
//   therefore costs ONE extra request: only the next request can prove that
//   the collection ended rather than the deployment clamping (a stub that
//   sends no `Content-Range` — the pre-#194 test transports — keeps the
//   one-request behaviour).
// - Consistency while paging (documented; not a transactional snapshot): a
//   concurrent INSERT is either visible inside a later page or not visible at
//   all. An UPDATE that moves a row LATER in the order can deliver that row
//   twice — identity dedupe keeps the first copy, so totals never double
//   count. An UPDATE that moves a row EARLIER in the order can miss it for
//   this read; the next read is complete again. A DELETE simply stops
//   appearing. The ledger's narrow read orders on immutable keys
//   (`created_at` + `id`), so those rows cannot migrate between pages.
// - Failure: a failed page throws out of the read. Callers never receive a
//   short array, so no partial snapshot can be cached or published.
// - No index is added: the existing `(user_id, eaten_at)` and
//   `(meal_log_id, created_at)` access paths already serve these ranges.
//
// The paged Today/History-graph seams live here (Repository.swift delegates to
// them): that file sits at the repo's 400-line `file_length` budget, the same
// reason #193 kept the ledger read in its own file.

/// Documented bounds for the collection read seams (issue #194).
enum BoundedRead {
    /// Rows requested per page. Supabase deployments cap a response at
    /// `db-max-rows` (Supabase's default is 1000); 200 stays well inside it
    /// and keeps a dense month (≤ 31 days) to a handful of requests.
    static let pageSize = 200
    /// Meal/menu ids per `in.(...)` request: bounded so the request URL stays
    /// far below any gateway's length limit.
    static let idChunkSize = 50
    /// Chunk requests in flight at once: one read's chunks are fetched one at
    /// a time, so a long id list cannot fan out.
    static let maxConcurrentChunks = 1
}

/// One page's rows plus the range the server reported covering them.
struct BoundedPage<Row> {
    let rows: [Row]
    /// `Content-Range`'s covered span (`last - first + 1`) when the server
    /// sent one: the deployment's EFFECTIVE page size, which can be smaller
    /// than the requested one.
    let covered: Int?

    init(rows: [Row], covered: Int? = nil) {
        self.rows = rows
        self.covered = covered
    }

    /// Reads `Content-Range: <first>-<last>/<total|*>`.
    init(rows: [Row], contentRange: String?) {
        self.rows = rows
        self.covered = contentRange.flatMap(Self.covered(_:))
    }

    private static func covered(_ header: String) -> Int? {
        guard let span = header.split(separator: "/").first else {
            return nil
        }
        let bounds = span.split(separator: "-").compactMap { Int($0) }
        guard bounds.count == 2, bounds[1] >= bounds[0] else {
            return nil
        }
        return bounds[1] - bounds[0] + 1
    }
}

/// The span a ranged response reported covering (`Content-Range:
/// <first>-<last>/<total|*>`), when the deployment reported one.
func reportedSpan(of response: HTTPURLResponse) -> String? {
    response.value(forHTTPHeaderField: "Content-Range")
}

extension PostgrestBuilder {
    /// Runs the ranged request and returns its rows with the span the
    /// deployment reported covering them (`Content-Range`). Naming the SDK's
    /// response type here is why this file sits on the contract test's raw-token
    /// allowlist (backend plumbing, never user-facing copy).
    func boundedPage<Row: Decodable>() async throws -> BoundedPage<Row> {
        let response: PostgrestResponse<[Row]> = try await execute()
        return BoundedPage(rows: response.value, contentRange: reportedSpan(of: response.response))
    }
}

extension SupabaseDashboardRepository {
    // MARK: - Bounded paging (issue #194)

    /// Reads one ordered collection to completion in bounded pages.
    ///
    /// `fetch` applies the caller's filters and the collection's total order,
    /// then the requested range. `identity` is the row's primary key — or the
    /// value pair that fully identifies a projected row — and `nil` for a
    /// projection that deliberately carries no key (see `chunkedRows`).
    func pagedRows<Row>(
        identity: (Row) -> String?,
        fetch: (_ offset: Int, _ limit: Int) async throws -> BoundedPage<Row>
    ) async throws -> [Row] {
        var rows: [Row] = []
        var seen = Set<String>()
        var offset = 0
        var pageSize = BoundedRead.pageSize
        while true {
            try Task.checkCancellation()
            let page = try await fetch(offset, pageSize)
            if page.rows.isEmpty {
                return rows
            }
            appendDeduped(page.rows, to: &rows, seen: &seen, identity: identity)
            // Advance by the rows actually received: a clamped deployment
            // answers fewer rows than asked for, and the next page must start
            // where this one ended.
            offset += page.rows.count
            if let covered = page.covered, covered < pageSize {
                pageSize = covered
                continue
            }
            if page.rows.count < pageSize {
                return rows
            }
        }
    }

    /// Reads a collection filtered by a long id list: the ids go out in
    /// bounded chunks (`BoundedRead.idChunkSize`) and every chunk is paged to
    /// completion. Chunks are sequential (`maxConcurrentChunks`), so a long
    /// list cannot fan out into a request storm.
    func chunkedRows<Row>(
        ids: [String],
        identity: (Row) -> String?,
        fetch: (_ ids: [String], _ offset: Int, _ limit: Int) async throws -> BoundedPage<Row>
    ) async throws -> [Row] {
        guard !ids.isEmpty else {
            return []
        }
        var rows: [Row] = []
        var seen = Set<String>()
        for start in stride(from: 0, to: ids.count, by: BoundedRead.idChunkSize) {
            try Task.checkCancellation()
            let chunk = Array(ids[start..<min(start + BoundedRead.idChunkSize, ids.count)])
            let chunkRows = try await pagedRows(
                identity: identity,
                fetch: { offset, limit in
                    try await fetch(chunk, offset, limit)
                }
            )
            appendDeduped(chunkRows, to: &rows, seen: &seen, identity: identity)
        }
        return rows
    }

    // MARK: - The paged collection seams

    // The Today/History-graph seams whose paged bodies live here (Repository.swift
    // sits at the 400-line lint cap and delegates); the ledger and menu seams stay
    // in their own files, where their private row types are declared.
    //
    // Every seam reads its pages through `boundedPage()` (defined above): it
    // keeps the ranged request, its rows and the `Content-Range` span the
    // deployment reported in one place.

    /// `loadMealLogs`: the day window's meal logs, paged on `eaten_at,id`.
    func pagedMealLogs(
        _ client: SupabaseClient, userID: UUID, start: Date, end: Date
    ) async throws -> [MealLogResponse] {
        try await pagedRows(
            identity: { $0.id },
            fetch: { offset, limit in
                try await client
                    .from("meal_logs")
                    .select("id,eaten_at,meal_type,source,image_path")
                    .eq("user_id", value: userID.uuidString)
                    .gte("eaten_at", value: MorselDate.iso8601(start))
                    .lt("eaten_at", value: MorselDate.iso8601(end))
                    .order("eaten_at", ascending: true).order("id", ascending: true)
                    .range(from: offset, to: offset + limit - 1)
                    .boundedPage()
            }
        )
    }

    /// `loadMealItems`: the day's items — bounded id chunks, each paged on
    /// `created_at,id`.
    func pagedMealItems(
        _ client: SupabaseClient, logs: [MealLogResponse]
    ) async throws -> [MealItemResponse] {
        try await chunkedRows(
            ids: logs.map(\.id),
            identity: { $0.id },
            fetch: { ids, offset, limit in
                try await client
                    .from("meal_items")
                    .select(mealItemColumns)
                    .in("meal_log_id", values: ids)
                    .order("created_at", ascending: true).order("id", ascending: true)
                    .range(from: offset, to: offset + limit - 1)
                    .boundedPage()
            }
        )
    }

    /// `loadWeightTrend`: the trend window's samples, paged on `measured_at,kg`
    /// (the pair is the whole identity of a projected sample).
    func pagedWeightTrend(
        _ client: SupabaseClient, userID: UUID, start: Date, end: Date
    ) async throws -> [WeightResponse] {
        try await pagedRows(
            identity: weightSampleIdentity,
            fetch: { offset, limit in
                try await client.from("weight_logs")
                    .select("measured_at,kg")
                    .eq("user_id", value: userID.uuidString)
                    .gte("measured_at", value: MorselDate.iso8601(start))
                    .lt("measured_at", value: MorselDate.iso8601(end))
                    .order("measured_at", ascending: true).order("kg", ascending: true)
                    .range(from: offset, to: offset + limit - 1)
                    .boundedPage()
            }
        )
    }
}

/// Appends a page's rows, keeping the FIRST delivered copy of each identity —
/// the value the snapshot already showed when an update moved a row later in
/// the order. A `nil` identity appends every row (a projection with immutable
/// ordering keys cannot migrate between pages).
private func appendDeduped<Row>(
    _ page: [Row], to rows: inout [Row], seen: inout Set<String>, identity: (Row) -> String?
) {
    for row in page {
        guard let key = identity(row) else {
            rows.append(row)
            continue
        }
        guard seen.insert(key).inserted else {
            continue
        }
        rows.append(row)
    }
}

/// The whole identity of a projected weight sample: `WeightResponse` carries
/// no id, and this pair is exactly the point the trend renders — a repeated
/// pair dedupes, a distinct pair never does.
func weightSampleIdentity(_ row: WeightResponse) -> String? {
    "\(row.measuredAt)|\(row.kilograms)"
}
