import AppKit
import Foundation
import Testing
@testable import OpenIslandApp

struct UsageThemeTests {
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
