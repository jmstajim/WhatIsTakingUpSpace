import Foundation
import Observation

/// Which of the two views of a result is on screen. The raw values are what is remembered
/// between launches.
nonisolated enum ResultMode: String, Sendable {
    case browse
    case largest
}

/// What is selected in each of the two views of a result.
nonisolated struct Selection: Equatable, Sendable {
    var browse: BrowserRow.ID?
    var largest: FileTree.NodeID?
}

/// What the window shows of a scan and what is picked in it. The toolbar, the views and the menu
/// bar all act through this, so that each command exists once.
@Observable
final class ScanWorkspace {
    private enum Key {
        static let mode = "resultMode"
        static let threshold = "largestThreshold"
        static let filter = "largestFilter"
    }

    /// Where Browse is. Good for scans of one root: another root has other folders.
    private struct Place {
        var rootPath: String?
        var history = BrowseHistory()
    }

    /// The selection together with the scan it was made in.
    private struct Picked {
        var scan: ScanOutcome.ID?
        var selection = Selection()
    }

    let session: ScanSession
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isPackage: (String) -> Bool

    var mode: ResultMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }

    /// What the Largest view counts as large; one of `CulpritThreshold.choices`.
    var threshold: Int64 {
        didSet { defaults.set(threshold, forKey: Key.threshold) }
    }

    var filter: CulpritFilter {
        didSet { defaults.set(filter.rawValue, forKey: Key.filter) }
    }

    /// What the Quick Look panel shows; `nil` while it is closed.
    var preview: URL?
    /// Set to ask the user for a folder to scan.
    var isChoosingFolder = false
    /// Set to ask the user where to save the report.
    var isSavingReport = false

    private var place = Place()
    private var picked = Picked()

    init(
        session: ScanSession,
        defaults: UserDefaults = .standard,
        isPackage: @escaping (String) -> Bool = PackageDetector().isPackage(name:)
    ) {
        self.session = session
        self.defaults = defaults
        self.isPackage = isPackage
        mode = defaults.string(forKey: Key.mode).flatMap(ResultMode.init) ?? .browse
        threshold = (defaults.object(forKey: Key.threshold) as? Int64).filter(CulpritThreshold.choices.contains)
            ?? CulpritThreshold.standard
        filter = defaults.string(forKey: Key.filter).flatMap(CulpritFilter.init) ?? .all
    }

    private var tree: FileTree? { session.outcome?.tree }

    // MARK: Scanning

    var isScanning: Bool { session.progress != nil }
    /// There is a result and no scan is replacing it. Also what leaving the result takes.
    var canRescan: Bool { session.outcome != nil && !isScanning }
    var canRescanShownFolder: Bool { canRescan && mode == .browse }

    func scanStartupDisk() {
        session.scan(rootPath: "/")
    }

    func scan(folder url: URL) {
        session.scan(folder: url)
    }

    func rescan() {
        session.rescan()
    }

    func rescanShownFolder() {
        session.rescan(folder: location)
    }

    /// Leaves the result for the start screen.
    func startNewScan() {
        session.close()
    }

    // MARK: Moving through folders

    private var history: BrowseHistory {
        get { place.rootPath == tree?.rootPath ? place.history : BrowseHistory() }
        set { place = Place(rootPath: tree?.rootPath, history: newValue) }
    }

    /// Names leading from the scan root to the folder Browse shows. Kept as names, not as a node,
    /// so that it survives a rescan.
    var location: [String] { history.location }

    /// The folder Browse shows: the one at `location`, or the nearest one above it that still exists.
    var shownFolder: FileTree.NodeID? { tree?.nearestDirectory(at: location) }

    var canGoBack: Bool { mode == .browse && history.canGoBack }
    var canGoUp: Bool { mode == .browse && shownFolder != tree?.root }
    var canOpenSelection: Bool { selectedDirectory != nil }

    func open(_ folder: FileTree.NodeID) {
        guard let tree else { return }
        history.go(to: tree.relativeComponents(of: folder))
        selection.browse = nil
    }

    func openSelection() {
        if let selectedDirectory { open(selectedDirectory) }
    }

    func goBack() {
        history.goBack()
        selection.browse = nil
    }

    /// Shows the enclosing folder with the one just left selected, the way Finder does.
    func goUp() {
        guard let tree, let folder = shownFolder, let parent = tree.parent(of: folder) else { return }
        history.go(to: tree.relativeComponents(of: parent))
        selection.browse = .node(folder)
    }

    /// Shows the folder `depth` levels below the scan root on the way to the one shown now.
    func go(toDepth depth: Int) {
        guard let tree, let folder = shownFolder else { return }
        history.go(to: Array(tree.relativeComponents(of: folder).prefix(depth)))
        selection.browse = nil
    }

    private var selectedDirectory: FileTree.NodeID? {
        guard mode == .browse, let tree, let node = selection.browse?.node, tree.kind(of: node) == .directory
        else { return nil }
        return node
    }

    // MARK: From Largest to Browse

    var canShowSelectionInBrowse: Bool { mode == .largest && selection.largest != nil }

    func showSelectionInBrowse() {
        if canShowSelectionInBrowse, let item = selection.largest { showInBrowse(item) }
    }

    func showInBrowse(_ node: FileTree.NodeID) {
        guard let tree else { return }
        let target = tree.browseTarget(for: node, isPackage: isPackage)
        history.go(to: target.location)
        selection.browse = target.selection
        mode = .browse
    }

    // MARK: What is selected

    /// Good for one scan: node IDs mean nothing in another, so a new scan starts with nothing selected.
    var selection: Selection {
        get { picked.scan == session.outcome?.id ? picked.selection : Selection() }
        set { picked = Picked(scan: session.outcome?.id, selection: newValue) }
    }

    /// What Show in Finder, Quick Look and Copy Path act on: the selected item, or in Browse, with
    /// no item selected, the folder shown.
    var targetPath: String? {
        guard let tree else { return nil }
        switch mode {
        case .browse: return tree.path(of: selection.browse?.node ?? tree.nearestDirectory(at: location))
        case .largest: return selection.largest.map(tree.path(of:))
        }
    }

    func togglePreview() {
        preview = preview == nil ? targetPath.map { URL(filePath: $0) } : nil
    }
}

private extension FileTree {
    nonisolated var rootPath: String { name(of: root) }
}

private extension Optional {
    nonisolated func filter(_ isIncluded: (Wrapped) -> Bool) -> Wrapped? {
        flatMap { isIncluded($0) ? $0 : nil }
    }
}
