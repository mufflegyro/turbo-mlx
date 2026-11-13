import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            ControlPanel()
                .navigationSplitViewColumnWidth(min: 360, ideal: 470, max: 600)
        } detail: {
            OutputPanel()
        }
        .navigationTitle("Turbo MLX")
        // The name stays the window's (Window menu, Mission Control) but not in the toolbar.
        .toolbar(removing: .title)
        // A sheet, as in the app this feature comes from: it stays in front until it is closed,
        // and cannot slip behind the window it belongs to.
        .sheet(isPresented: Binding(get: { app.showsPromptLibrary },
                                    set: { app.showsPromptLibrary = $0 })) {
            PromptLibraryView()
                .environment(app)
        }
        .alert(
            app.alert?.title ?? "",
            isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } }),
            presenting: app.alert
        ) { alert in
            if alert.offersLog {
                Button("Open Log") { openWindow(id: WindowID.log) }
            }
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }
}
