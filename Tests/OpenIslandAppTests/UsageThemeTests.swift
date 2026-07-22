import AppKit
import Foundation
import Testing
@testable import OpenIslandApp

struct UsageThemeTests {
    @Test
    func storyboardRequiresFourStagesAndCharacterRules() {
        let stages = UsageStoryboard.requiredRanges.map {
            UsageStoryboard.Stage(usageRange: $0, action: "waits", emotion: "eager")
        }
        let valid = UsageStoryboard(
            title: "Cookie Crocodile",
            characterInvariants: ["green crocodile"],
            stages: stages
        )
        #expect(valid.isValid)
        #expect(UsageStoryboard(title: "Invalid", characterInvariants: [], stages: stages).isValid == false)
        #expect(UsageStoryboard(title: "Invalid", characterInvariants: ["green crocodile"], stages: stages.reversed()).isValid == false)
    }

    @Test
    func decodesStoryboardFromCodexJSONOrMarkdownFence() throws {
        let json = #"{"title":"Cookie Crocodile","characterInvariants":["green crocodile"],"stages":[{"usageRange":"0-24","action":"waits","emotion":"eager"},{"usageRange":"25-49","action":"nibbles","emotion":"happy"},{"usageRange":"50-74","action":"bites","emotion":"focused"},{"usageRange":"75-100","action":"finishes","emotion":"satisfied"}]}"#

        #expect(UsageThemeGenerator.decodeStoryboard(Data(json.utf8))?.title == "Cookie Crocodile")
        #expect(UsageThemeGenerator.decodeStoryboard(Data("```json\n\(json)\n```".utf8))?.isValid == true)
    }

    @Test
    func codexErrorsRedactKeysAndExplainMissingImageTool() {
        let raw = "Incorrect API key sk-exampleSECRET123 and image_gen tool is not available"
        let sanitized = UsageThemeGenerator.sanitize(raw)

        #expect(sanitized.contains("sk-***"))
        #expect(!sanitized.contains("exampleSECRET123"))
        #expect(UsageThemeGenerator.imageFailureMessage(from: raw).contains("does not expose"))
    }

    @Test
    func shellQuotesPathsWithoutAllowingInterpolation() {
        #expect(CodexCLIExecutor.shellQuote("/tmp/a b") == "'/tmp/a b'")
        #expect(CodexCLIExecutor.shellQuote("a'b") == "'a'\\''b'")
    }

    @Test
    func mapsUsageToFourNarrativeFrames() {
        let theme = UsageTheme(
            id: UUID(),
            name: "Test",
            frames: ["one", "two", "three", "four"],
            createdAt: .now
        )

        #expect(theme.frameName(for: 0) == "one")
        #expect(theme.frameName(for: 24.9) == "one")
        #expect(theme.frameName(for: 25) == "two")
        #expect(theme.frameName(for: 50) == "three")
        #expect(theme.frameName(for: 75) == "four")
        #expect(theme.frameName(for: 100) == "four")
    }

    @Test
    func ordersImportedFramesByNaturalFilename() {
        let urls = [
            URL(fileURLWithPath: "/tmp/frame-4-75-100.png"),
            URL(fileURLWithPath: "/tmp/frame-1-0-24.png"),
            URL(fileURLWithPath: "/tmp/frame-3-50-74.png"),
            URL(fileURLWithPath: "/tmp/frame-2-25-49.png"),
        ]

        #expect(UsageThemeStore.orderedImageURLs(urls).map(\.lastPathComponent) == [
            "frame-1-0-24.png",
            "frame-2-25-49.png",
            "frame-3-50-74.png",
            "frame-4-75-100.png",
        ])
    }

    @Test
    func importsFourMatchingImagesAndReloadsManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-theme-tests-\(UUID().uuidString)")
        let input = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let urls = try (1...4).map { index in
            let url = input.appendingPathComponent("\(index).png")
            try pngData(width: 64, height: 64).write(to: url)
            return url
        }

        let store = UsageThemeStore(rootURL: root.appendingPathComponent("themes"))
        let theme = try store.importTheme(name: "Crocodile", imageURLs: urls)

        #expect(theme.frames.count == 4)
        let reloaded = store.loadTheme(id: theme.id)
        #expect(reloaded?.id == theme.id)
        #expect(reloaded?.name == theme.name)
        #expect(reloaded?.frames == theme.frames)
        #expect(FileManager.default.fileExists(
            atPath: store.imageURL(theme: theme, frameName: "frame-4.png").path
        ))
    }

    @Test
    func rejectsMismatchedImageDimensions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-theme-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = try (1...4).map { index in
            let url = root.appendingPathComponent("\(index).png")
            try pngData(width: index == 4 ? 32 : 64, height: 64).write(to: url)
            return url
        }

        #expect(throws: UsageThemeError.self) {
            _ = try UsageThemeStore(rootURL: root.appendingPathComponent("themes"))
                .importTheme(name: "Invalid", imageURLs: urls)
        }
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
