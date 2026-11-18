import QuickLook
import SwiftUI

/// A finished scan: the disk summary and, below it, the Browse or the Largest view.
struct ResultView: View {
    let outcome: ScanOutcome
    let workspace: ScanWorkspace

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            ResultHeader(outcome: outcome, session: workspace.session)
            Divider()
            switch workspace.mode {
            case .browse:
                BrowserView(tree: outcome.tree, rootTitle: rootTitle, workspace: workspace)
            case .largest:
                CulpritsView(tree: outcome.tree, workspace: workspace)
            }
        }
        .navigationTitle(rootTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                BackButton(workspace: workspace)
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $workspace.mode) {
                    Text("Browse").tag(ResultMode.browse)
                    Text("Largest").tag(ResultMode.largest)
                }
                .pickerStyle(.segmented)
                .help("Browse by folder or list the largest items")
            }
            ToolbarItem(placement: .primaryAction) {
                ExportMenu(outcome: outcome, workspace: workspace)
            }
            ToolbarItem(placement: .primaryAction) {
                ScanMenu(workspace: workspace)
            }
        }
        .quickLookPreview($workspace.preview)
        .modifier(ReportSaving(outcome: outcome, workspace: workspace))
    }

    /// The startup disk goes by its volume name; anything else by its folder name.
    private var rootTitle: String {
        let rootPath = outcome.tree.name(of: outcome.tree.root)
        if outcome.summary.coversWholeVolume, let name = VolumeName.ofVolume(holding: rootPath) { return name }
        return URL(filePath: rootPath).lastPathComponent
    }
}

/// The strip above the results: the disk summary, or the rescan that is about to replace it.
/// Kept apart so that progress reports redraw nothing else.
private struct ResultHeader: View {
    let outcome: ScanOutcome
    let session: ScanSession

    var body: some View {
        Group {
            if let progress = session.progress {
                ScanProgressStrip(progress: progress) { session.cancel() }
            } else {
                DiskSummaryView(summary: outcome.summary, tree: outcome.tree, unreadable: outcome.unreadable)
            }
        }
        .frame(minHeight: 36)
        .padding(.horizontal, Metrics.edge)
        .padding(.vertical, 10)
    }
}

/// Back through the folders Browse has shown. Kept apart, like the scan menu, so that the state
/// each reads redraws only itself.
private struct BackButton: View {
    let workspace: ScanWorkspace

    var body: some View {
        Button("Back", systemImage: "chevron.backward") { workspace.goBack() }
            .disabled(!workspace.canGoBack)
            .help("Show the previous folder")
    }
}

private struct ScanMenu: View {
    let workspace: ScanWorkspace

    var body: some View {
        Menu("Scan", systemImage: "arrow.clockwise") {
            Button("Rescan Everything") { workspace.rescan() }
            Button("Rescan This Folder") { workspace.rescanShownFolder() }
                .disabled(!workspace.canRescanShownFolder)
            Divider()
            Button("New Scan") { workspace.startNewScan() }
        } primaryAction: {
            workspace.rescan()
        }
        .disabled(!workspace.canRescan)
        .help("Scan again")
    }
}

#if DEBUG
private extension ScanOutcome {
    /// A startup disk that is half full, with most of the used space found in files.
    static let preview = ScanOutcome(
        tree: .preview,
        summary: DiskSummary(
            space: VolumeSpace(capacity: 494_000_000_000, free: 262_000_000_000, availableForImportantUsage: 271_000_000_000),
            foundInFiles: FileTree.preview.size(of: FileTree.preview.root),
            coversWholeVolume: true
        )
    )
}

private extension ScanWorkspace {
    /// Remembers its choices apart from the app's own, so that a preview cannot change them.
    static func preview(showing mode: ResultMode) -> ScanWorkspace {
        let workspace = ScanWorkspace(
            session: ScanSession(),
            defaults: UserDefaults(suiteName: "WhatIsTakingUpSpace.previews") ?? .standard
        )
        workspace.mode = mode
        workspace.threshold = CulpritThreshold.standard
        workspace.filter = .all
        return workspace
    }
}

#Preview("Browse") {
    ResultView(outcome: .preview, workspace: .preview(showing: .browse))
        .frame(width: 900, height: 520)
}

#Preview("Largest") {
    ResultView(outcome: .preview, workspace: .preview(showing: .largest))
        .frame(width: 900, height: 520)
}
#endif
