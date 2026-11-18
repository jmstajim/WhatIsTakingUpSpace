import SwiftUI

/// How full the disk is and how much of that the scan found.
struct DiskSummaryView: View {
    let summary: DiskSummary
    let tree: FileTree
    let unreadable: [FileTree.NodeID]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SummaryBar(fractions: summary.fractions, showsUnaccounted: summary.coversWholeVolume)
            HStack(spacing: 20) {
                Legend(color: SummaryColor.found, title: summary.coversWholeVolume ? "Found in files" : "This folder", bytes: summary.foundInFiles)
                if let unaccounted = summary.unaccounted {
                    UnaccountedLegend(bytes: unaccounted, purgeable: summary.purgeable)
                }
                Legend(color: SummaryColor.free, title: "Free", bytes: summary.free)
                Spacer()
                if !unreadable.isEmpty {
                    UnreadableButton(tree: tree, unreadable: unreadable)
                }
                Text("Capacity \(summary.capacity.formatted(.fileSize))")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}

/// The bar's colours stand for kinds of space. They are fixed ones and not the accent colour,
/// which the user sets in System Settings: an orange accent would make two segments look alike.
private enum SummaryColor {
    static let found = Color.blue
    static let unaccounted = Color.orange
    static let free = Color.secondary.opacity(0.3)
}

private struct SummaryBar: View {
    let fractions: DiskSummary.Fractions
    let showsUnaccounted: Bool

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                Rectangle().fill(SummaryColor.found).frame(width: proxy.size.width * fractions.found)
                Rectangle().fill(SummaryColor.unaccounted).frame(width: proxy.size.width * fractions.unaccounted)
                Rectangle().fill(SummaryColor.free)
            }
        }
        .frame(height: 10)
        .clipShape(.capsule)
        .accessibilityElement()
        .accessibilityLabel("Disk usage")
        .accessibilityValue(Text(spokenValue))
    }

    private var spokenValue: String {
        let percent = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))
        var parts = ["\(fractions.found.formatted(percent)) found in files"]
        if showsUnaccounted {
            parts.append("\(fractions.unaccounted.formatted(percent)) not found in files")
        }
        parts.append("\(fractions.free.formatted(percent)) free")
        return parts.joined(separator: ", ")
    }
}

private struct Legend: View {
    let color: Color
    let title: String
    let bytes: Int64

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
            SizeText(bytes: bytes)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The figure people ask about most, with a button that says what it is.
private struct UnaccountedLegend: View {
    let bytes: Int64
    let purgeable: Int64

    @State private var isExplaining = false

    var body: some View {
        HStack(spacing: 4) {
            Legend(color: SummaryColor.unaccounted, title: "Not found in files", bytes: bytes)
            Button("About Space Not Found in Files", systemImage: "info.circle") { isExplaining = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Explain what this space is")
                .popover(isPresented: $isExplaining, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Used space that is in no file the scan could read")
                            .font(.headline)
                        Text("It is made up of local Time Machine snapshots, data macOS removes by itself when space runs short (\(purgeable.formatted(.fileSize)) right now), and whatever is in folders the app has no access to.")
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 340)
                    .padding(14)
                }
        }
    }
}

/// Opens the list of folders the scan could not read.
private struct UnreadableButton: View {
    let tree: FileTree
    let unreadable: [FileTree.NodeID]

    @State private var isShowingList = false

    var body: some View {
        Button("No access: ^[\(unreadable.count) folder](inflect: true)", systemImage: "lock.fill") {
            isShowingList = true
        }
        .buttonStyle(.link)
        .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("These folders could not be read, so what they hold is not counted.")
                    .foregroundStyle(.secondary)
                List(unreadable, id: \.self) { node in
                    Text(verbatim: tree.path(of: node))
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contextMenu {
                            Button("Show in Finder") { FileActions.revealInFinder(tree.path(of: node)) }
                            Button("Copy Path") { FileActions.copy(tree.path(of: node)) }
                        }
                }
                .listStyle(.plain)
                // As tall as the list needs, up to ten rows; a longer one scrolls.
                .frame(height: CGFloat(min(unreadable.count, 10)) * 28)
            }
            .padding(12)
            .frame(width: 560)
        }
    }
}

#if DEBUG
#Preview("Whole disk") {
    DiskSummaryView(
        summary: DiskSummary(
            space: VolumeSpace(capacity: 994_000_000_000, free: 101_000_000_000, availableForImportantUsage: 150_000_000_000),
            foundInFiles: 752_000_000_000,
            coversWholeVolume: true
        ),
        tree: .preview,
        unreadable: [FileTree.preview.root]
    )
    .padding()
    .frame(width: 820)
}

#Preview("Folder") {
    DiskSummaryView(
        summary: DiskSummary(
            space: VolumeSpace(capacity: 994_000_000_000, free: 101_000_000_000, availableForImportantUsage: 101_000_000_000),
            foundInFiles: 130_000_000_000,
            coversWholeVolume: false
        ),
        tree: .preview,
        unreadable: []
    )
    .padding()
    .frame(width: 820)
}
#endif
