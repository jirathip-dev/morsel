import HealthKit

/// Read-only context, separate from the existing upload/import clock. A
/// successful permission prompt never proves permission: empty/denied reads
/// remain Unavailable. Each type is queried independently.
struct TrainingFuelHealthReader {
    private let store = HKHealthStore()

    func read(requestPermission: Bool = false, now: Date = Date()) async -> TrainingFuelContext {
        guard HKHealthStore.isHealthDataAvailable(),
              let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else {
            return TrainingFuelContext()
        }
        if requestPermission {
            do {
                try await store.requestAuthorization(toShare: [], read: [energy, HKObjectType.workoutType()])
            } catch { return TrainingFuelContext(movementFailed: true, workoutFailed: true) }
        }
        var context = TrainingFuelContext()
        do { context.movement = try await movement(energy, now: now) } catch { context.movementFailed = true }
        do { context.workout = try await workout(now: now) } catch { context.workoutFailed = true }
        return context
    }

    private func latest(_ type: HKSampleType, now: Date) async throws -> HKSample? {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: HKQuery.predicateForSamples(withStart: nil, end: now), limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume(returning: samples?.first)
                }
            }
            store.execute(query)
        }
    }

    private func movement(_ type: HKQuantityType, now: Date) async throws -> TrainingFuelReading? {
        guard let sample = try await latest(type, now: now) else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: sample.startDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        // HealthKit's cumulative statistics resolve overlapping device sources;
        // never sum a workout into Movement or use the body-mass upload stamp.
        let total: Double? = try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: min(end, now)),
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: .kilocalorie()))
                }
            }
            store.execute(query)
        }
        guard let total, total.isFinite else { return nil }
        return TrainingFuelReading(value: "\(MorselFormat.number(total)) kcal", sampleDate: sample.startDate,
                                   source: "Apple Health · active energy", checkedAt: Date())
    }

    private func workout(now: Date) async throws -> TrainingFuelReading? {
        guard let sample = try await latest(HKObjectType.workoutType(), now: now) as? HKWorkout else { return nil }
        let name: String
        switch sample.workoutActivityType {
        case .running: name = "Run"
        case .walking: name = "Walk"
        case .cycling: name = "Cycling"
        case .swimming: name = "Swim"
        case .traditionalStrengthTraining, .functionalStrengthTraining: name = "Strength training"
        default: name = "Workout"
        }
        return TrainingFuelReading(value: "\(name) · \(MorselFormat.number(sample.duration / 60)) min",
                                   sampleDate: sample.startDate,
                                   source: "Apple Health · \(sample.sourceRevision.source.name)", checkedAt: Date())
    }
}
