import SwiftUI

/// The Largest view: where the space really is, as one flat list in which nothing is counted twice.
struct CulpritsView: View {
    let tree: FileTree
    let workspace: ScanWorkspace

    var body: some View {
        let list = tree.culpritList(
            threshold: workspace.threshold,
            filter: workspace.filter,
            isPackage: PackageDetector().isPackage(name:)
        )
        VStack(spacing: 0) {
            controls
            Divider()
            CulpritsTable(tree: tree, rows: list.rows, workspace: workspace)
            Divider()
            CulpritsFooter(list: list, threshold: workspace.threshold)
        }
    }

    private var controls: some View {
        @Bindable var workspace = workspace
        return HStack(spacing: 16) {
            Picker("Show", selection: $workspace.filter) {
                Text("All").tag(CulpritFilter.all)
                Text("Folders").tag(CulpritFilter.folders)
                Text("Files").tag(CulpritFilter.files)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
            Picker("At least", selection: $workspace.threshold) {
                ForEach(CulpritThreshold.choices, id: \.self) { choice in
                    Text(choice, format: .fileSize).tag(choice)
                }
            }
            .fixedSize()
            .help("List items that hold at least this much of their own")
        }
        .padding(.horizontal, Metrics.edge)
        .padding(.vertical, 8)
    }
}

private struct CulpritsFooter: View {
    let list: CulpritList
    let threshold: Int64

    var body: some View {
        Text("Listed \(list.listedBytes.formatted(.fileSize)) of \(list.scannedBytes.formatted(.fileSize)) scanned. The rest is in pieces smaller than \(threshold.formatted(.fileSize)).")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.edge)
            .padding(.vertical, 6)
    }
}

/// Kept apart from the list's making, so that selecting a row or sorting by a column does not make
/// the parent work the list out again.
private struct CulpritsTable: View {
    let tree: FileTree
    let rows: [CulpritRow]
    let workspace: ScanWorkspace

    @State private var sortOrder = [KeyPathComparator(\CulpritRow.ownSize, order: .reverse)]

    var body: some View {
        @Bindable var workspace = workspace
        Table(rows.sorted(using: sortOrder), selection: $workspace.selection.largest, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                CulpritNameCell(row: row, path: tree.path(of: row.id))
            }
            TableColumn("Share of Scan") { row in
                ShareCell(fraction: row.fraction)
            }
            .width(min: 110, ideal: 150, max: 220)
            TableColumn("Size", value: \.ownSize) { row in
                SizeText(bytes: row.ownSize)
                    .fontWeight(.medium)
            }
            .width(min: 80, ideal: 96, max: 120)
            .alignment(.trailing)
            TableColumn("Whole Folder", value: \.totalSize) { row in
                if row.totalSize != row.ownSize {
                    SizeText(bytes: row.totalSize)
                        .foregroundStyle(.secondary)
                        .help("Size with the items listed separately")
                }
            }
            .width(min: 80, ideal: 100, max: 130)
            .alignment(.trailing)
        }
        .contextMenu(forSelectionType: CulpritRow.ID.self) { ids in
            if let node = ids.first {
                let path = tree.path(of: node)
                Button("Show in Browse") { workspace.showInBrowse(node) }
                Divider()
                Button("Show in Finder") { FileActions.revealInFinder(path) }
                Button("Quick Look") { workspace.preview = URL(filePath: path) }
                Button("Copy Path") { FileActions.copy(path) }
            }
        } primaryAction: { ids in
            if let node = ids.first { workspace.showInBrowse(node) }
        }
        .onKeyPress(.space) {
            workspace.togglePreview()
            return .handled
        }
        .onCopyCommand { CopiedPath.providers(for: workspace.targetPath) }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing This Large",
                    systemImage: "magnifyingglass",
                    description: Text("Choose a smaller size to see more.")
                )
            }
        }
    }
}

private struct CulpritNameCell: View {
    let row: CulpritRow
    let path: String

    var body: some View {
        HStack(spacing: 6) {
            FileIconView(path: path, kind: row.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !row.location.isEmpty {
                    Text(verbatim: row.location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview {
    CulpritsView(tree: .preview, workspace: ScanWorkspace(session: ScanSession()))
        .frame(width: 760, height: 420)
}
#endif
