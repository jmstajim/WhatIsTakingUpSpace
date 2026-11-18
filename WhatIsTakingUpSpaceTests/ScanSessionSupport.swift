import Foundation
import Synchronization
import Testing
@testable import WhatIsTakingUpSpace

/// Waits, yielding the main actor, until `condition` holds.
@MainActor
func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "condition never held")
        try await Task.sleep(for: .milliseconds(1))
    }
}

extension ScanOutcome {
    static func sample(root: String, size: Int64) -> ScanOutcome {
        of(.dir(root, [.dir("Users", [.dir("ada", [.file("movie", size)])])]))
    }

    /// The outcome of a whole-volume scan that found `spec`.
    static func of(_ spec: TreeSpec) -> ScanOutcome {
        let tree = FileTree(spec)
        let space = VolumeSpace(capacity: 100_000, free: 20_000, availableForImportantUsage: 20_000)
        return ScanOutcome(
            tree: tree,
            summary: DiskSummary(space: space, foundInFiles: tree.size(of: tree.root), coversWholeVolume: true)
        )
    }
}

/// A scanner that answers when the test tells it to.
final class StubScanner: Scanning {
    enum Call: Equatable {
        case scan(rootPath: String)
        case rescan(folder: [String], rootPath: String)
    }

    private struct Activity {
        var calls: [Call] = []
        var cancelledCalls = 0
        var report: (@Sendable (ScanProgress) -> Void)?
        var answers: [Result<ScanOutcome, any Error>] = []
    }

    private let activity = Mutex(Activity())

    var calls: [Call] { activity.withLock(\.calls) }
    /// How many calls ended because their task was cancelled.
    var cancelledCalls: Int { activity.withLock(\.cancelledCalls) }

    /// Lets the call that is waiting, or the next one, end with `result`.
    func finish(_ result: Result<ScanOutcome, any Error>) {
        activity.withLock { $0.answers.append(result) }
    }

    /// Sends a progress report through the most recent call's callback.
    func report(_ progress: ScanProgress) {
        activity.withLock(\.report)?(progress)
    }

    func scan(rootPath: String, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanOutcome {
        try await answer(.scan(rootPath: rootPath), progress)
    }

    func rescan(
        folder: [String],
        of previous: ScanOutcome,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanOutcome {
        try await answer(.rescan(folder: folder, rootPath: previous.tree.name(of: previous.tree.root)), progress)
    }

    private func answer(_ call: Call, _ progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanOutcome {
        activity.withLock {
            $0.calls.append(call)
            $0.report = progress
        }
        while !Task.isCancelled {
            if let answer = activity.withLock({ $0.answers.isEmpty ? nil : $0.answers.removeFirst() }) {
                return try answer.get()
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        activity.withLock { $0.cancelledCalls += 1 }
        throw CancellationError()
    }
}
