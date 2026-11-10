import AppKit
import FrameStackCore
import FrameStackMedia

// MARK: - Presets (PRD §9.2)

extension AppModel {
    var presets: [StoredPreset] { presetListing.presets }

    /// Re-reads the preset folder (files may have been added or removed in the Finder).
    func reloadPresets() {
        presetListing = presetStore.list()
    }

    /// The preset the current settings were made from, when nothing has changed since.
    var matchingPreset: StoredPreset? {
        presets.first { $0.preset.matches(settings, export: exportSettings) }
    }

    func presetExists(named name: String) -> Bool {
        presetStore.exists(name: name)
    }

    /// Saves the current creative settings as a named preset.
    @discardableResult
    func savePreset(named name: String, replacing: Bool = false) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            presetActivity = .failed("A preset needs a name.")
            return false
        }
        let preset = SettingsPreset(name: trimmed, settings: settings, export: exportSettings)
        do {
            try presetStore.save(preset, replacing: replacing)
            reloadPresets()
            presetActivity = .saved(trimmed)
            return true
        } catch {
            presetActivity = .failed(error.localizedDescription)
            return false
        }
    }

    /// Applies a preset as one undo step ("Apply Preset"); the time range,
    /// crop and painted strokes of the open document are kept.
    func applyPreset(_ stored: StoredPreset) {
        applyPreset(stored.preset)
    }

    func applyPreset(_ preset: SettingsPreset) {
        let framesInRange = try? selection?.get().eligibleCount
        let application = preset.apply(to: settings, framesInRange: framesInRange)
        pendingActionName = "Apply Preset"
        withUndoGroup {
            suppressChanges = true
            samplingKind = application.settings.samplingKind
            nth = application.settings.nth
            exactCount = application.settings.exactCount
            samplingPattern = application.settings.samplingPattern
            blendMode = application.settings.blendMode
            opacity = application.settings.opacity
            reverseOrder = application.settings.reverseOrder
            alignment = application.settings.alignment
            weighting = application.settings.weighting
            motionMask = application.settings.motionMask
            paintedMask = application.settings.paintedMask
            geometry = application.settings.geometry
            color = application.settings.color
            suppressChanges = false
            settingsChanged(debounce: false)
        }
        pendingActionName = nil
        exportSettings = application.export
        presetActivity = .applied(preset.name, notices: application.notices)
    }

    func deletePreset(_ stored: StoredPreset) {
        do {
            try presetStore.delete(stored)
            reloadPresets()
            presetActivity = .deleted(stored.preset.name)
        } catch {
            presetActivity = .failed(error.localizedDescription)
        }
    }

    func revealPresets() {
        try? FileManager.default.createDirectory(at: presetStore.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting(presets.map(\.url).isEmpty ? [presetStore.directory] : presets.map(\.url))
    }
}

// MARK: - Batch export (PRD §9.3)

extension AppModel {
    /// The outputs the current choice would produce, named for the folder they would go to.
    func batchVariants(for choice: BatchChoice) -> [BatchVariant] {
        var variants: [BatchVariant] = []
        func label(_ s: CompositeSettings) -> String {
            let opacityPart = s.blendMode.usesOpacity && s.opacity < 1 ? " \(Int((s.opacity * 100).rounded()))%" : ""
            return "\(s.blendMode.displayName)\(opacityPart)"
        }
        if choice.includeCurrent {
            variants.append(BatchVariant(id: "current", name: label(settings), settings: settings, export: exportSettings))
        }
        for mode in BlendMode.allCases where choice.blendModes.contains(mode) {
            var s = settings
            s.blendMode = mode
            variants.append(BatchVariant(id: "mode:\(mode.rawValue)", name: label(s), settings: s, export: exportSettings))
        }
        let framesInRange = try? selection?.get().eligibleCount
        for stored in presets where choice.presetURLs.contains(stored.url) {
            let applied = stored.preset.apply(to: settings, framesInRange: framesInRange)
            variants.append(BatchVariant(id: "preset:\(stored.url.path)", name: stored.preset.name, settings: applied.settings, export: applied.export))
        }
        // Two choices that mean the same output (Current = Average, plus Average ticked) are exported once.
        var seen: [BatchVariant] = []
        return variants.filter { v in
            if seen.contains(where: { $0.settings == v.settings && $0.export == v.export }) { return false }
            seen.append(v)
            return true
        }
    }

    var batchBaseName: String {
        projectName ?? (source.map { ($0.fileName as NSString).deletingPathExtension } ?? "FrameStack")
    }

    func batchPlan(for choice: BatchChoice, folder: URL) -> BatchPlan? {
        guard let source, let timeline else { return nil }
        return BatchPlan(source: source, timeline: timeline, baseName: batchBaseName, folder: folder, variants: batchVariants(for: choice))
    }

    var canStartBatch: Bool {
        canExport && !batchVariants(for: batchChoice).isEmpty
    }

    /// Asks for a folder, then exports every chosen variant into it.
    func presentBatchFolderPanel() {
        guard canStartBatch else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose the folder for the \(batchVariants(for: batchChoice).count) exports"
        // Start beside the project or the clip (a sequence's parent folder, not the stills themselves).
        if let projectURL {
            panel.directoryURL = projectURL.deletingLastPathComponent()
        } else if let source {
            panel.directoryURL = source.url.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            startBatch(choice: batchChoice, folder: url)
        }
    }

    func startBatch(choice: BatchChoice, folder: URL) {
        guard let plan = batchPlan(for: choice, folder: folder), !plan.variants.isEmpty, batch?.isRunning != true else { return }
        previewTask?.cancel()
        let outputs = BatchExporter.outputs(for: plan)
        batch = BatchState(folder: folder, outputs: outputs, summary: nil)
        let exporter = BatchExporter(renderer: renderer)
        batchTask = Task { [weak self] in
            let summary = await exporter.run(plan) { [weak self] outputs in
                Task { @MainActor [weak self] in
                    guard let self, self.batch?.isRunning == true else { return }
                    self.batch?.outputs = outputs
                }
            }
            guard let self else { return }
            self.batch?.outputs = summary.outputs
            self.batch?.summary = summary
            if !self.isPreviewCurrent { self.renderPreviewNow() }
        }
    }

    func cancelBatch() {
        batchTask?.cancel()
    }

    func dismissBatch() {
        guard batch?.isRunning != true else { return }
        batch = nil
    }

    func revealBatchFolder() {
        guard let batch else { return }
        let written = batch.outputs.compactMap { output -> URL? in
            if case .finished = output.status { return output.url }
            return nil
        }
        NSWorkspace.shared.activateFileViewerSelecting(written.isEmpty ? [batch.folder] : written)
    }
}
