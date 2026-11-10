import FrameStackCore
@testable import FrameStackMedia
import XCTest

final class PresetStoreTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackPresets-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func preset(_ name: String, mode: BlendMode = .average) -> SettingsPreset {
        let settings = CompositeSettings(rangeStart: .zero, rangeEnd: FrameTime(seconds: 1), samplingKind: .all, nth: 2, exactCount: 20,
                                         blendMode: mode, opacity: 1)
        return SettingsPreset(name: name, created: Date(timeIntervalSince1970: 1_700_000_000), settings: settings, export: ExportSettings())
    }

    func testSaveListReplaceDeleteAndProblems() throws {
        let store = PresetStore(directory: directory)
        XCTAssertEqual(store.list(), .empty, "a missing folder lists as empty")
        let url = try store.save(preset("Zebra Trails"))
        XCTAssertEqual(url.lastPathComponent, "Zebra Trails.framestackpreset")
        try store.save(preset("apple", mode: .lighten))
        try store.save(preset("Night/Sky:2", mode: .median))
        XCTAssertTrue(store.exists(name: "Night/Sky:2"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Night-Sky-2.framestackpreset").path))

        var listing = store.list()
        XCTAssertEqual(listing.presets.map(\.preset.name), ["apple", "Night/Sky:2", "Zebra Trails"], "Finder order, case-insensitive")
        XCTAssertEqual(listing.problems, [])

        XCTAssertThrowsError(try store.save(preset("apple", mode: .darken))) { error in
            XCTAssertEqual(error as? PresetError, .exists(name: "apple"))
        }
        XCTAssertEqual(try PresetStore.read(from: store.url(for: "apple")).blendMode, .lighten, "refused save changed nothing")
        try store.save(preset("apple", mode: .darken), replacing: true)
        XCTAssertEqual(try PresetStore.read(from: store.url(for: "apple")).blendMode, .darken)

        // A file from a newer FrameStack and a damaged file are reported, not fatal.
        try Data(#"{"formatVersion": 99, "name": "Future", "blendMode": "average"}"#.utf8).write(to: directory.appendingPathComponent("future.framestackpreset"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.framestackpreset"))
        try Data("ignored".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        listing = store.list()
        XCTAssertEqual(listing.presets.count, 3)
        XCTAssertEqual(listing.problems.count, 2)
        XCTAssertTrue(listing.problems.contains { $0.contains("future") && $0.contains("newer version") }, "\(listing.problems)")
        XCTAssertTrue(listing.problems.contains { $0.contains("broken") && $0.contains("not a valid") }, "\(listing.problems)")

        try store.delete(listing.presets[0])
        XCTAssertEqual(store.list().presets.map(\.preset.name), ["Night/Sky:2", "Zebra Trails"])

        // The file is readable JSON with sorted keys and an ISO date.
        let text = try String(contentsOf: store.url(for: "Zebra Trails"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"created\" : \"2023-11-14T22:13:20Z\""), text)
        XCTAssertTrue(text.contains("\"formatVersion\" : 1"))
    }
}

final class BatchNamingTests: XCTestCase {
    func testNamesAreDeterministicAndCollisionSafe() {
        let folder = URL(fileURLWithPath: "/tmp/out")
        let names = ["clip Average 24f.png", "clip Lighten 24f.png", "clip Average 24f.png", "CLIP average 24F.png", "clip Average 24f 2.png"]
        let existing: Set<String> = ["clip Lighten 24f.png", "clip Average 24f 3.png"]
        // The mock folder is case-insensitive like APFS.
        let exists: (URL) -> Bool = { url in existing.contains { $0.lowercased() == url.lastPathComponent.lowercased() } }
        let urls = BatchNaming.uniqueURLs(for: names, in: folder, exists: exists)
        XCTAssertEqual(urls.map(\.lastPathComponent), [
            "clip Average 24f.png",
            "clip Lighten 24f 2.png", // taken on disk
            "clip Average 24f 2.png", // taken by the first output
            "CLIP average 24F 4.png", // 2 taken above, 3 taken on disk; names are compared case-insensitively
            "clip Average 24f 2 2.png", // the literal " 2" name is taken by the third output
        ])
        XCTAssertEqual(Set(urls.map { $0.lastPathComponent.lowercased() }).count, urls.count, "no two outputs share a file")
        XCTAssertEqual(urls, BatchNaming.uniqueURLs(for: names, in: folder, exists: exists), "deterministic")
        XCTAssertEqual(BatchNaming.fileName(base: "clip", variant: "Normal 30%", frameCount: 12, longEdge: 1080, format: .jpeg), "clip Normal 30% 12f 1080px.jpg")
        XCTAssertEqual(BatchNaming.fileName(base: "clip", variant: "Average", frameCount: 12, longEdge: nil, format: .tiff), "clip Average 12f.tif")
    }
}

final class BatchExportTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackBatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func settings(_ clip: LoadedFixture, mode: BlendMode) -> CompositeSettings {
        CompositeSettings(rangeStart: .zero, rangeEnd: FrameTime(seconds: clip.info.duration.seconds + 1), samplingKind: .all, nth: 2, exactCount: 20,
                          blendMode: mode, opacity: 1)
    }

    func testVariantsSharingACompositeRenderOnceAndEveryOutputIsVerified() async throws {
        let clip = try await loadFixture(.movingSquare)
        var bright = settings(clip, mode: .average)
        bright.color.exposure = 1
        var cropped = settings(clip, mode: .average)
        cropped.geometry.crop = NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
        let variants = [
            BatchVariant(name: "Average", settings: settings(clip, mode: .average), export: ExportSettings(format: .png, bitDepth: .eight)),
            BatchVariant(name: "Lighten", settings: settings(clip, mode: .lighten), export: ExportSettings(format: .png, bitDepth: .eight)),
            BatchVariant(name: "Bright", settings: bright, export: ExportSettings(format: .png, bitDepth: .eight)),
            BatchVariant(name: "Half", settings: cropped, export: ExportSettings(format: .jpeg)),
            BatchVariant(name: "Small", settings: settings(clip, mode: .average), export: ExportSettings(format: .png, bitDepth: .eight, sizing: .longEdge(240))),
        ]
        // A file that is already there must not be overwritten.
        let taken = directory.appendingPathComponent("square Lighten 24f.png")
        try Data("keep me".utf8).write(to: taken)
        let plan = BatchPlan(source: .video(clip.info), timeline: clip.timeline, baseName: "square", folder: directory, variants: variants)

        let planned = BatchExporter.outputs(for: plan)
        XCTAssertEqual(planned.map(\.url.lastPathComponent), [
            "square Average 24f.png", "square Lighten 24f 2.png", "square Bright 24f.png", "square Half 24f 272px.jpg", "square Small 24f 240px.png",
        ])
        XCTAssertEqual(planned[0].sharesRenderWith, ["Bright", "Half"], "colour and crop variants reuse the Average composite")
        XCTAssertEqual(planned[4].sharesRenderWith, [], "a different output size is a different render")
        XCTAssertEqual(BatchExporter.renderPassCount(for: variants, native: clip.info.displaySize), 3)

        final class Log: @unchecked Sendable {
            var updates: [[BatchOutput]] = []
            let lock = NSLock()
            func add(_ o: [BatchOutput]) { lock.lock(); updates.append(o); lock.unlock() }
        }
        let log = Log()
        let summary = await BatchExporter(renderer: sharedRenderer).run(plan) { log.add($0) }

        XCTAssertEqual(summary.rendersPerformed, 3)
        XCTAssertEqual(summary.finishedCount, 5)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(summary.cancelledCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), [
            "square Average 24f.png", "square Bright 24f.png", "square Half 24f 272px.jpg", "square Lighten 24f 2.png", "square Lighten 24f.png", "square Small 24f 240px.png",
        ], "five outputs beside the untouched file; no temporary files")
        XCTAssertEqual(try String(contentsOf: taken, encoding: .utf8), "keep me")

        // Every output passed the exporter's read-back and the files are what the variants asked for.
        for output in summary.outputs {
            guard case let .finished(report, missing) = output.status else { return XCTFail("\(output.variant.name): \(output.status)") }
            XCTAssertEqual(missing, 0)
            XCTAssertEqual(report.url, output.url)
            XCTAssertEqual(try ImageExporter.inspect(output.url).width, report.width)
        }
        let average = try readBackPixels(summary.outputs[0].url, bitDepth: .eight)
        let bright8 = try readBackPixels(summary.outputs[2].url, bitDepth: .eight)
        XCTAssertEqual(average.width, 480)
        // The gray bar (rows 200…239) at +1 EV is twice as bright in linear light.
        let barAvg = SRGBTransfer.decode(average.rgb[(220 * 480 + 240) * 3])
        let barBright = SRGBTransfer.decode(bright8.rgb[(220 * 480 + 240) * 3])
        XCTAssertEqual(barBright / barAvg, 2, accuracy: 0.05)
        XCTAssertEqual(try ImageExporter.inspect(summary.outputs[3].url).width, 240, "half crop at native size; the name carries the cropped long edge")
        XCTAssertEqual(try ImageExporter.inspect(summary.outputs[4].url).width, 240)

        // Status reporting: every output went pending → rendering → writing → finished, and the
        // three shared variants were marked rendering together.
        let last = try XCTUnwrap(log.updates.last)
        XCTAssertEqual(last.map(\.status), summary.outputs.map(\.status))
        let renderingTogether = log.updates.contains { update in
            if case .rendering = update[0].status, case .rendering = update[2].status, case .rendering = update[3].status,
               update[1].status == .pending, update[4].status == .pending { return true }
            return false
        }
        XCTAssertTrue(renderingTogether, "the Average group renders once while the others wait")
        XCTAssertTrue(log.updates.contains { $0[0].status == .writing })
        for (i, update) in log.updates.enumerated().dropFirst() {
            for (a, b) in zip(log.updates[i - 1], update) {
                if a.status.isFinal { XCTAssertEqual(a.status, b.status, "a final status never changes") }
            }
        }
    }

    func testCancellationStopsAfterTheCurrentOutputAndLeavesNoPartialFiles() async throws {
        let clip = try await loadFixture(.count)
        let variants = [
            BatchVariant(name: "Average", settings: settings(clip, mode: .average), export: ExportSettings(format: .png, bitDepth: .eight)),
            BatchVariant(name: "Lighten", settings: settings(clip, mode: .lighten), export: ExportSettings(format: .png, bitDepth: .eight)),
            BatchVariant(name: "Darken", settings: settings(clip, mode: .darken), export: ExportSettings(format: .png, bitDepth: .eight)),
        ]
        let plan = BatchPlan(source: .video(clip.info), timeline: clip.timeline, baseName: "count", folder: directory, variants: variants)
        final class Gate: @unchecked Sendable {
            let lock = NSLock()
            var firstFinished = false
            func note(_ outputs: [BatchOutput]) { lock.lock(); if case .finished = outputs[0].status { firstFinished = true }; lock.unlock() }
            var done: Bool { lock.lock(); defer { lock.unlock() }; return firstFinished }
        }
        let gate = Gate()
        let task = Task { await BatchExporter(renderer: sharedRenderer).run(plan) { gate.note($0) } }
        while !gate.done { try await Task.sleep(nanoseconds: 5_000_000) }
        task.cancel()
        let summary = await task.value
        XCTAssertEqual(summary.finishedCount, 1)
        XCTAssertEqual(summary.cancelledCount, 2, "\(summary.outputs.map(\.status))")
        XCTAssertLessThanOrEqual(summary.rendersPerformed, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["count Average 150f.png"], "only the finished output exists")
    }

    func testAVariantThatCannotBeSampledFailsAloneAndMedianRendersInBands() async throws {
        let clip = try await loadFixture(.movingSquare)
        var bad = settings(clip, mode: .average)
        bad.samplingKind = .exactCount
        bad.exactCount = 0
        var sparse = settings(clip, mode: .median)
        sparse.samplingKind = .everyNth
        sparse.nth = 4
        let variants = [
            BatchVariant(name: "Bad", settings: bad, export: ExportSettings(format: .png, bitDepth: .eight)),
            BatchVariant(name: "Median", settings: sparse, export: ExportSettings(format: .png, bitDepth: .eight)),
        ]
        let plan = BatchPlan(source: .video(clip.info), timeline: clip.timeline, baseName: "square", folder: directory, variants: variants)
        let summary = await BatchExporter(renderer: sharedRenderer).run(plan) { _ in }
        guard case let .failed(message) = summary.outputs[0].status else { return XCTFail("\(summary.outputs[0].status)") }
        XCTAssertTrue(message.contains("count"), message)
        guard case let .finished(report, _) = summary.outputs[1].status else { return XCTFail("\(summary.outputs[1].status)") }
        XCTAssertEqual(report.url.lastPathComponent, "square Median 6f.png", "the variant's own sampling (every 4th of 24)")
        XCTAssertEqual(summary.rendersPerformed, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["square Median 6f.png"])
    }
}
