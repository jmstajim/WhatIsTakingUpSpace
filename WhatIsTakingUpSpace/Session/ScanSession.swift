import Foundation
import Observation

/// Why a scan did not finish, in words for the user.
nonisolated struct ScanFailure: Equatable, Sendable {
    var message: String

    init(message: String) {
        self.message = message
    }

    init(_ error: any Error) {
        message = error.localizedDescription
    }
}

/// What the window is doing: waiting to be told what to scan, scanning, or showing a result.
@Observable
final class ScanSession {
    private enum State {
        /// Nothing scanned yet. `failure` is set when the last attempt to scan failed.
        case idle(failure: ScanFailure?)
        /// A scan is running. `returningTo` is the result on screen before it started, if any:
        /// what cancelling goes back to.
        case scanning(ScanProgress, returningTo: ScanOutcome?)
        /// A finished scan. `failure` is set when a rescan failed and this older result stayed.
        case showing(ScanOutcome, failure: ScanFailure?)

        var outcome: ScanOutcome? {
            switch self {
            case .idle: nil
            case let .scanning(_, previous): previous
            case let .showing(outcome, _): outcome
            }
        }

        var progress: ScanProgress? {
            if case let .scanning(progress, _) = self { progress } else { nil }
        }

        var failure: ScanFailure? {
            switch self {
            case let .idle(failure), let .showing(_, failure): failure
            case .scanning: nil
            }
        }
    }

    /// The one source of truth. Views observe the three properties below, each of which changes
    /// only when its own part of the state does: a progress report does not disturb a view that
    /// shows the result.
    @ObservationIgnored private var state = State.idle(failure: nil) {
        didSet { publish() }
    }

    /// The scan on screen; while a rescan runs, the one it will replace.
    private(set) var outcome: ScanOutcome?
    /// Set while a scan is running.
    private(set) var progress: ScanProgress?
    /// Why the last scan did not finish, until dismissed or the next scan starts.
    private(set) var failure: ScanFailure?

    private let scanner: any Scanning
    /// How long a progress report stays on screen before the next one may replace it.
    private let progressPause: Duration
    /// The scan in flight. Tests await it.
    private(set) var activeScan: Task<Void, Never>?
    /// Identifies the scan whose results are still wanted; a cancelled or replaced scan loses it.
    private var currentRun: UUID?

    init(scanner: any Scanning = DiskScanner(), progressPause: Duration = .milliseconds(50)) {
        self.scanner = scanner
        self.progressPause = progressPause
    }

    private func publish() {
        if outcome?.id != state.outcome?.id { outcome = state.outcome }
        progress = state.progress
        failure = state.failure
    }

    /// Scans a disk or a folder from scratch. `rootPath` is absolute and free of symlinks.
    func scan(rootPath: String) {
        run(showing: rootPath) { scanner, report in
            try await scanner.scan(rootPath: rootPath, progress: report)
        }
    }

    /// Scans the folder at `url`, wherever it really is.
    func scan(folder url: URL) {
        guard let rootPath = ScanRoot.canonicalPath(of: url) else {
            return refuse("“\(url.lastPathComponent)” can’t be opened.")
        }
        // The folder panel offers folders only, but a drop or the Dock hands over anything.
        guard ScanRoot.isFolder(rootPath) else {
            return refuse("“\(url.lastPathComponent)” is not a folder.")
        }
        scan(rootPath: rootPath)
    }

    private func refuse(_ message: String) {
        state = Self.resting(on: outcome, failure: ScanFailure(message: message))
    }

    /// Repeats the scan now on screen.
    func rescan() {
        rescan(folder: [])
    }

    /// Brings one folder of the scan on screen up to date. `folder` is named by the path
    /// components leading to it from the scan root.
    func rescan(folder: [String]) {
        guard let previous = outcome else { return }
        let path = previous.tree.path(of: previous.tree.nearestDirectory(at: folder))
        run(showing: path) { scanner, report in
            try await scanner.rescan(folder: folder, of: previous, progress: report)
        }
    }

    /// Stops the running scan and goes back to what was on screen before it.
    func cancel() {
        guard case let .scanning(_, previous) = state else { return }
        activeScan?.cancel()
        currentRun = nil
        state = Self.resting(on: previous, failure: nil)
    }

    /// Leaves the result and goes back to choosing what to scan.
    func close() {
        guard case .showing = state else { return }
        state = .idle(failure: nil)
    }

    func dismissFailure() {
        guard failure != nil else { return }
        state = Self.resting(on: outcome, failure: nil)
    }

    private typealias Report = @Sendable (ScanProgress) -> Void

    private func run(
        showing path: String,
        _ work: @escaping (any Scanning, @escaping Report) async throws -> ScanOutcome
    ) {
        activeScan?.cancel()
        let run = UUID()
        let previous = outcome
        currentRun = run
        state = .scanning(ScanProgress(filesSeen: 0, bytesSeen: 0, currentPath: path), returningTo: previous)
        let (reports, reporting) = AsyncStream.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        activeScan = Task { [scanner] in
            let display = Task { await self.show(reports, of: run) }
            let finished = await Result { try await work(scanner) { reporting.yield($0) } }
            reporting.finish()
            await display.value
            self.finish(run, with: finished, returningTo: previous)
        }
    }

    /// Shows the newest report, then lets it stay a moment: a scan reports far more often than
    /// anyone can read, and the reports in between are dropped.
    private func show(_ reports: AsyncStream<ScanProgress>, of run: UUID) async {
        for await report in reports {
            guard currentRun == run, case let .scanning(_, previous) = state else { return }
            state = .scanning(report, returningTo: previous)
            try? await Task.sleep(for: progressPause)
        }
    }

    private func finish(_ run: UUID, with result: Result<ScanOutcome, any Error>, returningTo previous: ScanOutcome?) {
        guard currentRun == run else { return }
        currentRun = nil
        switch result {
        case let .success(outcome):
            state = .showing(outcome, failure: nil)
        case .failure(is CancellationError):
            state = Self.resting(on: previous, failure: nil)
        case let .failure(error):
            state = Self.resting(on: previous, failure: ScanFailure(error))
        }
    }

    private static func resting(on outcome: ScanOutcome?, failure: ScanFailure?) -> State {
        outcome.map { .showing($0, failure: failure) } ?? .idle(failure: failure)
    }
}

/// The path a scan starts from.
nonisolated enum ScanRoot {
    /// The absolute path of the folder at `url` with every symlink resolved, as the scanner needs it.
    /// `nil` when there is nothing at `url`.
    static func canonicalPath(of url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
