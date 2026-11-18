import SwiftUI

/// The Browse view: the contents of one folder, largest first, and the way back up.
struct BrowserView: View {
    let tree: FileTree
    /// What the scan root is called in the path bar.
    let rootTitle: String
    let workspace: ScanWorkspace

    var body: some View {
        let folder = tree.nearestDirectory(at: workspace.location)
        VStack(spacing: 0) {
            PathBar(crumbs: [rootTitle] + tree.relativeComponents(of: folder), onSelect: workspace.go(toDepth:))
            Divider()
            BrowserTable(
                tree: tree,
                folder: folder,
                rows: tree.browserRows(of: folder, isPackage: PackageDetector().isPackage(name:)),
                workspace: workspace
            )
        }
    }
}

/// The folders from the scan root down to the one shown; each but the last takes you back to itself.
private struct PathBar: View {
    let crumbs: [String]
    /// Called with how many components below the root to keep.
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { depth, name in
                    if depth > 0 {
                        Image(systemName: "chevron.compact.right")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    if depth == crumbs.count - 1 {
                        // Where you are: said plainly, with nothing to click.
                        Text(verbatim: name)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 4)
                            .accessibilityAddTraits(.isHeader)
                    } else {
                        Button { onSelect(depth) } label: {
                            Text(verbatim: name)
                                .padding(.horizontal, 4)
                                .frame(minHeight: 22)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, Metrics.edge - 4)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.never)
        // A long path shows its end; a short one sits at the leading edge.
        .defaultScrollAnchor(.trailing, for: .initialOffset)
        .defaultScrollAnchor(.trailing, for: .sizeChanges)
        .defaultScrollAnchor(.leading, for: .alignment)
        .accessibilityLabel("Path")
    }
}

/// The rows of one folder, in the order the column headings ask for.
private struct BrowserTable: View {
    let tree: FileTree
    let folder: FileTree.NodeID
    let rows: [BrowserRow]
    let workspace: ScanWorkspace

    @State private var sortOrder = [KeyPathComparator(\BrowserRow.size, order: .reverse)]

    var body: some View {
        @Bindable var workspace = workspace
        Table(rows.arranged(by: sortOrder), selection: $workspace.selection.browse, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                BrowserNameCell(row: row, path: path(of: row))
            }
            TableColumn("Share") { row in
                ShareCell(fraction: row.fraction)
            }
            .width(min: 110, ideal: 200, max: 280)
            TableColumn("Size", value: \.size) { row in
                SizeText(bytes: row.size)
            }
            .width(min: 80, ideal: 96, max: 120)
            .alignment(.trailing)
        }
        .contextMenu(forSelectionType: BrowserRow.ID.self) { ids in
            menu(for: ids.first.flatMap(row(with:)))
        } primaryAction: { ids in
            if let row = ids.first.flatMap(row(with:)), row.canEnter, let node = row.node { workspace.open(node) }
        }
        .onKeyPress(.space) {
            workspace.togglePreview()
            return .handled
        }
        .onCopyCommand { CopiedPath.providers(for: workspace.targetPath) }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "folder", description: Text("This folder takes no space."))
            }
        }
    }

    private func row(with id: BrowserRow.ID) -> BrowserRow? {
        rows.first { $0.id == id }
    }

    /// A row's own path, or the shown folder's for the loose-files row and for empty space.
    private func path(of row: BrowserRow?) -> String {
        tree.path(of: row?.node ?? folder)
    }

    @ViewBuilder
    private func menu(for row: BrowserRow?) -> some View {
        let path = path(of: row)
        if let row, row.canEnter, let node = row.node {
            Button("Open") { workspace.open(node) }
            Divider()
        }
        Button(row?.node == nil ? "Show Folder in Finder" : "Show in Finder") { FileActions.revealInFinder(path) }
        Button("Quick Look") { workspace.preview = URL(filePath: path) }
        Button("Copy Path") { FileActions.copy(path) }
    }
}

private struct BrowserNameCell: View {
    let row: BrowserRow
    let path: String

    var body: some View {
        HStack(spacing: 6) {
            icon
            title
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.node == nil ? .secondary : .primary)
            FlagBadge(flags: row.flags)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let kind = row.kind.item {
            FileIconView(path: path, kind: kind)
        } else {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(.secondary)
                .frame(width: FileIconView.side)
                .accessibilityLabel("Small files")
        }
    }

    private var title: Text {
        if case let .looseFiles(count) = row.kind {
            Text("^[\(count) file](inflect: true) under \(LooseFiles.cutoff.formatted(.fileSize))")
        } else {
            // A file name is shown as it is, never looked up as a localized string.
            Text(verbatim: row.name)
        }
    }
}

#if DEBUG
#Preview {
    BrowserView(tree: .preview, rootTitle: "Macintosh HD", workspace: ScanWorkspace(session: ScanSession()))
        .frame(width: 760, height: 420)
}
#endif
