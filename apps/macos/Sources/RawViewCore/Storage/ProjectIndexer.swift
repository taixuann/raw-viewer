import Foundation

public struct ProjectIndexRunReport: Sendable, Equatable, Codable {
    public let discovered: Int
    public let inspected: Int
    public let deterministicBlocked: Int
    public let transientFailures: Int
    public let inventoryFailures: Int
    public let structuralCandidates: Int
    public let cancelled: Int
    public let complete: Bool
    public let storageMode: IndexUsage.StorageMode

    public init(
        discovered: Int,
        inspected: Int,
        deterministicBlocked: Int,
        transientFailures: Int,
        inventoryFailures: Int,
        structuralCandidates: Int,
        cancelled: Int,
        complete: Bool,
        storageMode: IndexUsage.StorageMode
    ) {
        self.discovered = discovered
        self.inspected = inspected
        self.deterministicBlocked = deterministicBlocked
        self.transientFailures = transientFailures
        self.inventoryFailures = inventoryFailures
        self.structuralCandidates = structuralCandidates
        self.cancelled = cancelled
        self.complete = complete
        self.storageMode = storageMode
    }
}

public enum ProjectIndexer {
    public static let batchSize = 256

    public static func run(
        project: ProjectContext,
        rebuild: Bool = false,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ProjectIndexRunReport {
        let store = try await ProjectIndexStore.open(project: project)
        let usage = try await store.usage()

        return try await store.withWriterJob {
            let inventory = try await project.discoverInventoryAsync()
            let sources = inventory.sources
            let discoveredCount = sources.count
            let inventoryFailuresCount = inventory.issues.count

            var inspectedCount = 0
            var deterministicBlockedCount = 0
            var transientFailuresCount = 0
            var structuralCandidatesCount = 0
            var cancelledCount = 0

            let totalBatches = max(1, (discoveredCount + batchSize - 1) / batchSize)
            var batchIndex = 0

            let cache = MeasurementCache(project: project)

            while batchIndex * batchSize < discoveredCount {
                if Task.isCancelled {
                    let unvisited = discoveredCount - (batchIndex * batchSize)
                    cancelledCount += unvisited
                    break
                }

                let start = batchIndex * batchSize
                let end = min(start + batchSize, discoveredCount)
                let batchSlice = Array(sources[start..<end])

                var batchResults: [SourceInspectionResult] = []
                batchResults.reserveCapacity(batchSlice.count)

                for source in batchSlice {
                    if Task.isCancelled {
                        cancelledCount += 1
                        continue
                    }

                    if !rebuild, let restored = try? await store.validatedInspection(for: source, project: project) {
                        batchResults.append(restored)
                        inspectedCount += 1
                        switch restored.disposition {
                        case .profileMatched:
                            break
                        case .structuralCandidate:
                            structuralCandidatesCount += 1
                        case .deterministicBlocked:
                            deterministicBlockedCount += 1
                        case .transientFailure:
                            transientFailuresCount += 1
                        case .cancelled:
                            cancelledCount += 1
                        }
                        continue
                    }

                    let freshReport = await InstrumentReader.inspectMany([source], project: project, cache: cache)
                    if let result = freshReport.results.first {
                        batchResults.append(result)
                        switch result.disposition {
                        case .profileMatched:
                            inspectedCount += 1
                        case .structuralCandidate:
                            inspectedCount += 1
                            structuralCandidatesCount += 1
                        case .deterministicBlocked:
                            inspectedCount += 1
                            deterministicBlockedCount += 1
                        case .transientFailure:
                            transientFailuresCount += 1
                        case .cancelled:
                            cancelledCount += 1
                        }
                    } else {
                        transientFailuresCount += 1
                    }
                }

                if !batchResults.isEmpty {
                    try await store.recordBatch(batchResults, project: project)
                }

                batchIndex += 1
                onProgress?(batchIndex, totalBatches)

                if Task.isCancelled {
                    let unvisited = discoveredCount - end
                    cancelledCount += unvisited
                    break
                }
            }

            let isComplete = (transientFailuresCount == 0 && inventoryFailuresCount == 0 && cancelledCount == 0)

            if isComplete {
                let discoveredSet = Set(sources.map(\.relativePath))
                try? await store.deleteStale(discoveredPaths: discoveredSet, project: project)
            }

            return ProjectIndexRunReport(
                discovered: discoveredCount,
                inspected: inspectedCount,
                deterministicBlocked: deterministicBlockedCount,
                transientFailures: transientFailuresCount,
                inventoryFailures: inventoryFailuresCount,
                structuralCandidates: structuralCandidatesCount,
                cancelled: cancelledCount,
                complete: isComplete,
                storageMode: usage.storageMode
            )
        }
    }
}
