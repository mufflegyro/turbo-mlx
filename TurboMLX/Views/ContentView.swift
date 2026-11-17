import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The window's content size, read from the layout as it is when the sheet opens: the
        // gallery sizes itself after it (nine tenths, within limits), so it has to be live — a
        // GeometryReader hands the sheet the proxy itself, not a size captured once.
        GeometryReader { window in
            NavigationSplitView {
                ControlPanel()
                    .navigationSplitViewColumnWidth(min: 360, ideal: 470, max: 600)
            } detail: {
                OutputPanel()
            }
            .navigationTitle("Turbo MLX")
            // The name stays the window's (Window menu, Mission Control) but not in the toolbar.
            .toolbar(removing: .title)
            // One sheet at a time, whichever of the two is asked for (a sheet, as in the app
            // this feature comes from: it stays in front until it is closed, and cannot slip
            // behind the window it belongs to). A menu command while one is up — ⇧⌘G with
            // Styles & Prompts open — switches to the other rather than queue a second sheet.
            .sheet(item: Binding(get: { app.presentedSheet }, set: { app.presentedSheet = $0 })) { sheet in
                switch sheet {
                case .promptLibrary:
                    PromptLibraryView()
                        .environment(app)
                case .gallery:
                    GalleryView(windowSize: window.size, initiallyShowing: app.galleryScrollsTo)
                        .environment(app)
                }
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
}
