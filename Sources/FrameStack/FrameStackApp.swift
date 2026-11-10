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
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(model.recentFiles, id: \.path) { url in
                        Button(url.lastPathComponent) { model.open(url) }
                            .help(url.path)
                    }
                    if !model.recentFiles.isEmpty {
                        Divider()
                        Button("Clear Menu") { model.clearRecentFiles() }
                    }
                }
                .disabled(model.recentFiles.isEmpty)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { model.saveProject() }
                    .keyboardShortcut("s")
                    .disabled(!model.canSaveProject)
                Button("Save Project As…") { model.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canSaveProject)
                Divider()
                Button("Export Image…") { model.presentExportPanel() }
                    .keyboardShortcut("e")
                    .disabled(!model.canExport)
                Button("Batch Export…") { model.isBatchSheetPresented = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.canExport && model.batch == nil)
            }
            CommandGroup(before: .toolbar) {
                Picker("Show", selection: $model.viewMode) {
                    Text("Composite").tag(PreviewViewMode.composite).keyboardShortcut("1", modifiers: [.command, .option])
                    Text("Original Frame").tag(PreviewViewMode.original).keyboardShortcut("2", modifiers: [.command, .option])
                    Text("Side by Side").tag(PreviewViewMode.sideBySide).keyboardShortcut("3", modifiers: [.command, .option])
                }
                .pickerStyle(.inline)
                Divider()
                Button("Zoom to Fit") { model.zoomToFit() }
                    .keyboardShortcut("0")
                Button("Actual Size") { model.zoomActualSize() }
                    .keyboardShortcut("1")
                Button("Zoom In") { model.zoomIn(viewport: AppDelegate.previewViewport) }
                    .keyboardShortcut("=")
                Button("Zoom Out") { model.zoomOut(viewport: AppDelegate.previewViewport) }
                    .keyboardShortcut("-")
                Divider()
                Toggle("Crop on Preview", isOn: $model.isEditingCrop)
                    .keyboardShortcut("k")
                    .disabled(!model.canEditCrop)
                Divider()
            }
            CommandMenu("Frame") {
                Button("Previous Frame") { model.stepScrub(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                Button("Next Frame") { model.stepScrub(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: .option)
                Button("Back 10 Frames") { model.stepScrub(by: -10) }
                    .keyboardShortcut(.leftArrow, modifiers: [.option, .shift])
                Button("Forward 10 Frames") { model.stepScrub(by: 10) }
                    .keyboardShortcut(.rightArrow, modifiers: [.option, .shift])
                Divider()
                Button("Set In Point at Playhead") { model.setInPointAtPlayhead() }
                    .keyboardShortcut("i", modifiers: .option)
                    .disabled(model.scrubIndex == nil)
                Button("Set Out Point at Playhead") { model.setOutPointAtPlayhead() }
                    .keyboardShortcut("o", modifiers: .option)
                    .disabled(model.scrubIndex == nil)
                Button("Go to Range Start") { if let r = model.frameRange { model.scrubIndex = r.lowerBound } }
                    .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
                Button("Go to Range End") { if let r = model.frameRange { model.scrubIndex = r.upperBound } }
                    .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
                Divider()
                Button("Full Clip") { model.resetRange() }
                    .keyboardShortcut("f", modifiers: [.option, .command])
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
    /// The window's model, for the quit-with-unsaved-changes prompt.
    weak var model: AppModel?

    /// Size of the preview area, reported by the view so menu zoom steps can
    /// start from the current "fit" scale.
    nonisolated(unsafe) static var previewViewport = CGSize(width: 1000, height: 700)

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

    /// Standard Save / Don't Save / Cancel prompt when quitting with unsaved
    /// project changes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasUnsavedChanges else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(model.windowTitle)” before quitting?"
        alert.informativeText = model.projectURL == nil
            ? "The time range, sampling, blend and export settings will be lost unless you save them as a project."
            : "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return model.saveProject() ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
