import SwiftUI

/// The menu bar: every command of the toolbar and of the context menus, with its shortcut.
/// Each group is a view of its own so that it follows the state it reads.
struct AppCommands: Commands {
    let workspace: ScanWorkspace

    var body: some Commands {
        CommandGroup(replacing: .newItem) { ScanCommands(workspace: workspace) }
        CommandGroup(replacing: .saveItem) { ItemCommands(workspace: workspace) }
        CommandGroup(after: .pasteboard) { CopyCommands(workspace: workspace) }
        CommandGroup(before: .toolbar) { ViewCommands(workspace: workspace) }
        CommandMenu("Go") { GoCommands(workspace: workspace) }
        // The app has no help book, and the system's item would only say so.
        CommandGroup(replacing: .help) {}
    }
}

private struct ScanCommands: View {
    let workspace: ScanWorkspace

    private static let diskName = StartupDisk.current().name

    var body: some View {
        Button("New Scan", action: workspace.startNewScan)
            .keyboardShortcut("n")
            .disabled(!workspace.canRescan)
        Button("Scan \(Self.diskName)", action: workspace.scanStartupDisk)
            .disabled(workspace.isScanning)
        Button("Choose Folder…") { workspace.isChoosingFolder = true }
            .keyboardShortcut("o")
            .disabled(workspace.isScanning)
        Divider()
        Button("Rescan Everything", action: workspace.rescan)
            .keyboardShortcut("r")
            .disabled(!workspace.canRescan)
        Button("Rescan This Folder", action: workspace.rescanShownFolder)
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!workspace.canRescanShownFolder)
    }
}

/// What is done with the report and with the selected item.
private struct ItemCommands: View {
    let workspace: ScanWorkspace

    var body: some View {
        let target = workspace.targetPath
        Button("Save Report…") { workspace.isSavingReport = true }
            .keyboardShortcut("s")
            .disabled(workspace.session.outcome == nil)
        Divider()
        Button("Show in Finder") { if let target { FileActions.revealInFinder(target) } }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(target == nil)
        Button("Quick Look", action: workspace.togglePreview)
            .keyboardShortcut("y")
            .disabled(target == nil)
    }
}

private struct CopyCommands: View {
    let workspace: ScanWorkspace

    var body: some View {
        let target = workspace.targetPath
        let outcome = workspace.session.outcome
        Divider()
        Button("Copy Path") { if let target { FileActions.copy(target) } }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(target == nil)
        Button("Copy Report") {
            if let outcome { FileActions.copy(ReportFile(outcome: outcome, threshold: workspace.threshold).text) }
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(outcome == nil)
    }
}

private struct ViewCommands: View {
    let workspace: ScanWorkspace

    var body: some View {
        @Bindable var workspace = workspace
        let hasResult = workspace.session.outcome != nil
        Toggle("Browse", isOn: showing(.browse))
            .keyboardShortcut("1")
            .disabled(!hasResult)
        Toggle("Largest", isOn: showing(.largest))
            .keyboardShortcut("2")
            .disabled(!hasResult)
        Divider()
        Group {
            Picker("Show in Largest", selection: $workspace.filter) {
                Text("All").tag(CulpritFilter.all)
                Text("Folders").tag(CulpritFilter.folders)
                Text("Files").tag(CulpritFilter.files)
            }
            Picker("Largest Starts At", selection: $workspace.threshold) {
                ForEach(CulpritThreshold.choices, id: \.self) { choice in
                    Text(choice, format: .fileSize).tag(choice)
                }
            }
        }
        .disabled(!hasResult || workspace.mode != .largest)
        Divider()
    }

    /// A checkmark on the view that is on screen; choosing the other one switches to it.
    private func showing(_ mode: ResultMode) -> Binding<Bool> {
        Binding(get: { workspace.mode == mode }, set: { _ in workspace.mode = mode })
    }
}

private struct GoCommands: View {
    let workspace: ScanWorkspace

    var body: some View {
        Button("Back", action: workspace.goBack)
            .keyboardShortcut("[")
            .disabled(!workspace.canGoBack)
        Button("Enclosing Folder", action: workspace.goUp)
            .keyboardShortcut(.upArrow)
            .disabled(!workspace.canGoUp)
        Button("Open", action: workspace.openSelection)
            .keyboardShortcut(.downArrow)
            .disabled(!workspace.canOpenSelection)
        Divider()
        Button("Show in Browse", action: workspace.showSelectionInBrowse)
            .disabled(!workspace.canShowSelectionInBrowse)
    }
}
