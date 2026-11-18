import SwiftUI

@main
struct WhatIsTakingUpSpaceApp: App {
    @State private var workspace = ScanWorkspace(session: ScanSession())

    var body: some Scene {
        // The scene's title names the window in the Window menu; each screen titles the window itself.
        Window("What Is Taking Up Space", id: "main") {
            RootView(workspace: workspace)
        }
        .defaultSize(width: 980, height: 680)
        .commands { AppCommands(workspace: workspace) }
    }
}
