import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// The findings report as something to share, copy or save. The text is worked out when it is
/// asked for: going through a whole scan takes a moment, and most of the time nobody asks.
nonisolated struct ReportFile: Transferable, Sendable {
    static let contentType = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
    static let name = "Disk Usage Report"

    let outcome: ScanOutcome
    /// The one chosen in the Largest view, so the report lists what that view lists.
    let threshold: Int64

    /// What the scan found, as text to hand to someone who can say what the folders are.
    var text: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return outcome.tree
            .findingsReport(
                summary: outcome.summary,
                unreadable: outcome.unreadable,
                threshold: threshold,
                isPackage: PackageDetector().isPackage(name:)
            )
            .markdown(
                madeAt: .now,
                on: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            )
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: contentType) { file in
            Data(file.text.utf8)
        }
        .suggestedFileName("\(name).md")
    }
}

/// The toolbar menu that takes the findings out of the app.
struct ExportMenu: View {
    let outcome: ScanOutcome
    let workspace: ScanWorkspace

    var body: some View {
        let report = ReportFile(outcome: outcome, threshold: workspace.threshold)
        Menu("Export", systemImage: "square.and.arrow.up") {
            ShareLink(item: report, preview: SharePreview(ReportFile.name))
            Divider()
            Button("Copy Report") { FileActions.copy(report.text) }
            Button("Save Report…") { workspace.isSavingReport = true }
        }
        .help("Share, copy or save what was found as text")
    }
}

/// The save panel for the report, opened from the toolbar or the File menu.
/// Writing the file the user asks for is the only thing the app ever puts on disk.
struct ReportSaving: ViewModifier {
    let outcome: ScanOutcome
    let workspace: ScanWorkspace

    @State private var hasFailed = false
    @State private var failureReason = ""

    func body(content: Content) -> some View {
        @Bindable var workspace = workspace
        content
            .fileExporter(
                isPresented: $workspace.isSavingReport,
                item: ReportFile(outcome: outcome, threshold: workspace.threshold),
                contentTypes: [ReportFile.contentType],
                defaultFilename: ReportFile.name,
                onCompletion: noteOutcome
            )
            .alert("The report couldn’t be saved.", isPresented: $hasFailed) {
                Button("OK") {}
            } message: {
                Text(failureReason)
            }
    }

    /// A cancelled panel is not reported here at all, so every failure is worth showing.
    private func noteOutcome(_ result: Result<URL, any Error>) {
        guard case let .failure(error) = result else { return }
        failureReason = error.localizedDescription
        hasFailed = true
    }
}
