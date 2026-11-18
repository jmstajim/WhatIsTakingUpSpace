import SwiftUI
import UniformTypeIdentifiers

/// The window's content: the start screen, the first scan, or a result.
struct RootView: View {
    let workspace: ScanWorkspace

    var body: some View {
        @Bindable var workspace = workspace
        // A result stays in the hierarchy under a running rescan so that it keeps its place.
        Group {
            if let outcome = workspace.session.outcome {
                ResultView(outcome: outcome, workspace: workspace)
            } else {
                StartOrFirstScan(workspace: workspace)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .fileImporter(isPresented: $workspace.isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { workspace.scan(folder: url) }
        }
        .fileDialogConfirmationLabel("Scan")
        // A folder dropped on the window, or on the app's icon, is scanned.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            workspace.scan(folder: url)
            return true
        }
        .onOpenURL { workspace.scan(folder: $0) }
        .modifier(FailureAlert(session: workspace.session))
    }
}

/// Kept apart so that progress reports redraw nothing else.
private struct StartOrFirstScan: View {
    let workspace: ScanWorkspace

    var body: some View {
        if let progress = workspace.session.progress {
            ScanProgressView(progress: progress, onCancel: workspace.session.cancel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Scanning")
        } else {
            StartView(workspace: workspace)
                .navigationTitle("New Scan")
        }
    }
}

private struct FailureAlert: ViewModifier {
    let session: ScanSession

    func body(content: Content) -> some View {
        content.alert(
            "The scan couldn’t be completed.",
            isPresented: Binding(get: { session.failure != nil }, set: { if !$0 { session.dismissFailure() } }),
            presenting: session.failure
        ) { _ in
            Button("OK") { session.dismissFailure() }
        } message: { failure in
            Text(failure.message)
        }
    }
}

#if DEBUG
#Preview("Start") {
    RootView(workspace: ScanWorkspace(session: ScanSession()))
}
#endif
