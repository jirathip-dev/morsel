import Foundation

/// One account's day read. Freshness joins; writes invalidate the current pass;
/// cancellation/supersession releases ownership even if the repository ignores it.
@MainActor
final class TodayRefreshOwner {
    enum Event {
        case cached(DashboardSnapshot), loaded(DashboardSnapshot), failed(Error), finished
    }

    final class Flight {
        let date: Date
        let publish: (Event) -> Void
        var revision = 0
        var error: Error?
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        var keepsAlive = false

        init(date: Date, publish: @escaping (Event) -> Void) {
            self.date = date
            self.publish = publish
        }
    }

    private let repository: any DashboardRepository
    private let userID: UUID
    private var active: Flight?

    init(repository: any DashboardRepository, userID: UUID) {
        self.repository = repository
        self.userID = userID
    }

    func start(date: Date, needsCache: Bool, invalidating: Bool, superseding: Bool,
               keepsAlive: Bool = false, publish: @escaping (Event) -> Void) -> Flight {
        if superseding || active?.date != date { cancel() }
        if let active {
            if invalidating { active.revision &+= 1 }
            active.keepsAlive = active.keepsAlive || keepsAlive
            return active
        }
        let flight = Flight(date: date, publish: publish)
        flight.keepsAlive = keepsAlive
        active = flight
        read(flight, needsCache: needsCache && !invalidating)
        return flight
    }

    func wait(for flight: Flight) async {
        let waiter = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard active === flight, !Task.isCancelled else {
                    continuation.resume()
                    if Task.isCancelled { cancelWaiter(waiter, flight: flight) }
                    return
                }
                flight.waiters[waiter] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(waiter, flight: flight) }
        }
    }

    func cancel() {
        guard let flight = active else { return }
        active = nil
        flight.error = CancellationError()
        flight.task?.cancel()
        flight.task = nil
        flight.publish(.finished)
        resumeWaiters(flight)
    }

    private func cancelWaiter(_ waiter: UUID, flight: Flight) {
        flight.waiters.removeValue(forKey: waiter)?.resume()
        if active === flight, flight.waiters.isEmpty, !flight.keepsAlive { cancel() }
    }

    private func read(_ flight: Flight, needsCache: Bool) {
        let revision = flight.revision
        flight.task = Task { [weak self, repository, userID] in
            if needsCache, let cached = try? await repository.cachedToday(userID: userID, date: flight.date) {
                if self?.active === flight, flight.revision == revision, !Task.isCancelled {
                    flight.publish(.cached(cached))
                }
            }
            guard self?.active === flight, !Task.isCancelled else { return }
            // A write while the cache was parked must not start a pre-write pass.
            guard flight.revision == revision else {
                self?.read(flight, needsCache: false)
                return
            }
            let result: Result<DashboardSnapshot, Error>
            do {
                result = .success(try await repository.loadToday(userID: userID, date: flight.date))
            } catch {
                result = .failure(error)
            }
            self?.complete(flight, revision: revision, result: result)
        }
    }

    private func complete(_ flight: Flight, revision: Int, result: Result<DashboardSnapshot, Error>) {
        guard active === flight else { return }
        if revision != flight.revision {
            read(flight, needsCache: false)
            return
        }
        if case .failure(let error) = result { flight.error = error }
        switch result {
        case .success(let snapshot): flight.publish(.loaded(snapshot))
        case .failure(let error) where !(error is CancellationError): flight.publish(.failed(error))
        case .failure: break
        }
        active = nil
        flight.task = nil
        flight.publish(.finished)
        resumeWaiters(flight)
    }

    private func resumeWaiters(_ flight: Flight) {
        let waiters = flight.waiters.values
        flight.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
