import AppKit
import SwiftUI

@main
struct FrameStackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("FrameStack", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
                // Files opened from Finder ("Open With", drop on the Dock
                // icon, `open -a FrameStack clip.mov`) or passed on the
                // command line at launch.
                .onReceive(appDelegate.$requestedURL.compactMap { $0 }) { url in
                    model.open(url)
                    appDelegate.requestedURL = nil
                }
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Export PNG…") { model.presentExportPanel() }
                    .keyboardShortcut("e")
                    .disabled(!model.canExport)
            }
            CommandMenu("Render") {
                Button("Render Preview Now") { model.renderPreviewNow() }
                    .keyboardShortcut("r")
                    .disabled(model.source == nil)
                Button("Cancel Rendering") { model.cancelRendering() }
                    .keyboardShortcut(".")
            }
        }
    }
}

/// When launched with `swift run` (no app bundle) macOS treats the process as
/// a background tool; make it a regular foreground app with a Dock icon and
/// menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// A file the system or the command line asked us to open; consumed by
    /// the main window.
    @Published var requestedURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // `FrameStack /path/to/clip.mov` (also `open -a FrameStack --args …`).
        // Launch Services opens Finder documents via application(_:open:)
        // instead, so only accept an argument that names an existing file.
        if requestedURL == nil,
           let path = CommandLine.arguments.dropFirst().last(where: { !$0.hasPrefix("-") }),
           FileManager.default.fileExists(atPath: path) {
            requestedURL = URL(fileURLWithPath: path)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { requestedURL = url }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
