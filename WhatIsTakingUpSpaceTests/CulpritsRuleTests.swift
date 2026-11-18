import Foundation
import Testing
@testable import WhatIsTakingUpSpace

/// Checks `culprits` against the rule as the user agreed it, restated top-down and without any
/// pruning, on many small random trees. Sizes and thresholds are a handful of bytes so that
/// "exactly at the threshold" and equal own sizes come up all the time.
struct CulpritsRuleTests {
    @Test(arguments: [1, 2, 3, 5, 8, 13, 21, 34] as [Int64])
    func randomTreesFollowTheAgreedRule(threshold: Int64) {
        var random = SplitMix64(state: UInt64(threshold))
        for _ in 0..<300 {
            let tree = FileTree(.randomRoot(using: &random))

            let culprits = tree.culprits(threshold: threshold, isPackage: isTestPackage)

            let facts = culprits.map { Fact(tree, $0) }
            #expect(Set(facts) == tree.factsByTheRule(threshold: threshold), "\(tree.outline)")
            // Strictly ordered also means nothing is listed twice.
            #expect(zip(facts, facts.dropFirst()).allSatisfy { $0.isListedBefore($1) }, "\(facts)")
        }
    }

    /// The generator must really produce what the rule distinguishes, or the test above proves little.
    @Test func randomTreesCoverEveryKindOfCulpritAndTies() {
        var random = SplitMix64(state: 7)
        var kinds: Set<Culprit.Kind> = []
        var sawTie = false
        var sawPackageNamedRootSplit = false
        for _ in 0..<300 {
            let tree = FileTree(.randomRoot(using: &random))
            let culprits = tree.culprits(threshold: 5, isPackage: isTestPackage)
            kinds.formUnion(culprits.map(\.kind))
            sawTie = sawTie || Set(culprits.map(\.ownSize)).count < culprits.count
            sawPackageNamedRootSplit = sawPackageNamedRootSplit
                || (isTestPackage(tree.name(of: tree.root)) && culprits.contains { $0.node != tree.root })
        }

        #expect(kinds == [.folder, .file, .package])
        #expect(sawTie)
        #expect(sawPackageNamedRootSplit)
    }
}

private func isTestPackage(_ name: String) -> Bool { name.hasSuffix(".app") }

/// What the user reads off one row.
private struct Fact: Hashable, CustomStringConvertible {
    var path: String
    var kind: Culprit.Kind
    var own: Int64
    var total: Int64

    var description: String { "\(path) [\(kind)] own \(own) of \(total)" }

    func isListedBefore(_ next: Fact) -> Bool {
        own > next.own || (own == next.own && path < next.path)
    }
}

private extension Fact {
    init(_ tree: FileTree, _ culprit: Culprit) {
        self.init(path: tree.path(of: culprit.node), kind: culprit.kind, own: culprit.ownSize, total: culprit.totalSize)
    }

    init(_ tree: FileTree, whole node: FileTree.NodeID, kind: Culprit.Kind) {
        self.init(path: tree.path(of: node), kind: kind, own: tree.size(of: node), total: tree.size(of: node))
    }
}

private extension FileTree {
    /// The rule, read straight off the spec: start at the root, split folders, take the rest whole.
    func factsByTheRule(threshold: Int64) -> Set<Fact> {
        size(of: root) >= threshold ? facts(ofLarge: root, threshold: threshold) : []
    }

    /// `node` is known to reach the threshold.
    private func facts(ofLarge node: NodeID, threshold: Int64) -> Set<Fact> {
        if kind(of: node) == .file { return [Fact(self, whole: node, kind: .file)] }
        if node != root, isTestPackage(name(of: node)) { return [Fact(self, whole: node, kind: .package)] }
        let large = children(of: node).filter { size(of: $0) >= threshold }
        let own = size(of: node) - large.map(size(of:)).reduce(0, +)
        let below = large.map { facts(ofLarge: $0, threshold: threshold) }.reduce(into: Set<Fact>()) { $0.formUnion($1) }
        guard own >= threshold else { return below }
        return below.union([Fact(path: path(of: node), kind: .folder, own: own, total: size(of: node))])
    }

    /// One line per node, for reading a failure.
    var outline: String {
        var lines: [String] = []
        var pending = [root]
        while let node = pending.popLast() {
            lines.append("\(path(of: node)) = \(size(of: node)) loose \(loose(of: node).bytes)")
            pending.append(contentsOf: children(of: node))
        }
        return lines.joined(separator: "\n")
    }
}

private extension TreeSpec {
    static func randomRoot(using random: inout SplitMix64) -> TreeSpec {
        let rootPath = ["/", "/Users/ada", "/Volumes/Stick/", "/Applications/Root.app"].randomElement(using: &random) ?? "/"
        return randomDirectory(named: rootPath, levelsBelow: 4, using: &random)
    }

    private static func randomDirectory(named name: String, levelsBelow: Int, using random: inout SplitMix64) -> TreeSpec {
        let children = (0..<Int.random(in: 0...4, using: &random)).map { index -> TreeSpec in
            switch Int.random(in: 0..<(levelsBelow > 0 ? 6 : 2), using: &random) {
            case 0, 1: .file("file-\(index)", Int64.random(in: 0...12, using: &random))
            case 2: randomDirectory(named: "bundle-\(index).app", levelsBelow: levelsBelow - 1, using: &random)
            default: randomDirectory(named: "dir-\(index)", levelsBelow: levelsBelow - 1, using: &random)
            }
        }
        return .dir(name, children, loose: LooseFiles(count: 1, bytes: Int64.random(in: 0...6, using: &random)))
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
