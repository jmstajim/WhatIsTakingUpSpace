/// Where the Browse view is and where it has been, so that Back can return there.
nonisolated struct BrowseHistory: Equatable, Sendable {
    /// Names leading from the scan root to the folder shown. Empty at the root.
    private(set) var location: [String] = []
    /// The places left behind, oldest first.
    private var earlier: [[String]] = []

    var canGoBack: Bool { !earlier.isEmpty }

    /// Shows `place`. Going where you already are leaves nothing to go back to.
    mutating func go(to place: [String]) {
        guard place != location else { return }
        earlier.append(location)
        location = place
    }

    mutating func goBack() {
        guard let last = earlier.popLast() else { return }
        location = last
    }
}
