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
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
