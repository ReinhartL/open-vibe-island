import AppKit
import Foundation

struct UsageTheme: Codable, Equatable, Identifiable, Sendable {
    static let frameCount = 4
    static let thresholds = [0.0, 25.0, 50.0, 75.0]

    let id: UUID
    var name: String
    var frames: [String]
    var createdAt: Date

    func frameName(for usedPercentage: Double) -> String? {
        guard frames.count == Self.frameCount else { return nil }
        let value = min(100, max(0, usedPercentage))
        let index = Self.thresholds.lastIndex(where: { value >= $0 }) ?? 0
        return frames[index]
    }
}

enum UsageThemeError: LocalizedError {
    case requiresFourImages
    case unreadableImage(String)
    case mismatchedDimensions
    case imageTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .requiresFourImages:
            "Select exactly four images."
        case .unreadableImage(let name):
            "Could not read \(name)."
        case .mismatchedDimensions:
            "All four images must have identical dimensions."
        case .imageTooLarge(let name):
            "\(name) exceeds the 10 MB limit."
        }
    }
}

struct UsageThemeStore {
    static let selectedThemeDefaultsKey = "appearance.usageTheme.selectedID"
    static let maximumImageBytes = 10 * 1_024 * 1_024

    private let fileManager: FileManager
    let rootURL: URL

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenIsland/UsageThemes", isDirectory: true)
    }

    func importTheme(name: String, imageURLs: [URL]) throws -> UsageTheme {
        guard imageURLs.count == UsageTheme.frameCount else { throw UsageThemeError.requiresFourImages }

        var images: [(url: URL, image: NSImage)] = []
        for url in imageURLs {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if values.fileSize ?? 0 > Self.maximumImageBytes {
                throw UsageThemeError.imageTooLarge(url.lastPathComponent)
            }
            guard let image = NSImage(contentsOf: url), image.isValid else {
                throw UsageThemeError.unreadableImage(url.lastPathComponent)
            }
            images.append((url, image))
        }

        return try persist(name: name, images: images.map(\.image))
    }

    func importTheme(name: String, imageData: [Data]) throws -> UsageTheme {
        guard imageData.count == UsageTheme.frameCount else { throw UsageThemeError.requiresFourImages }
        let images = try imageData.enumerated().map { index, data in
            guard data.count <= Self.maximumImageBytes,
                  let image = NSImage(data: data), image.isValid else {
                throw UsageThemeError.unreadableImage("frame-\(index + 1)")
            }
            return image
        }
        return try persist(name: name, images: images)
    }

    private func persist(name: String, images: [NSImage]) throws -> UsageTheme {
        guard let size = images.first?.pixelSize,
              images.dropFirst().allSatisfy({ $0.pixelSize == size }) else {
            throw UsageThemeError.mismatchedDimensions
        }

        let theme = UsageTheme(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom Usage Theme" : name,
            frames: (1...UsageTheme.frameCount).map { "frame-\($0).png" },
            createdAt: .now
        )
        let directory = directoryURL(for: theme)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for (index, image) in images.enumerated() {
            guard let png = image.pngData else {
                throw UsageThemeError.unreadableImage("frame-\(index + 1)")
            }
            try png.write(to: directory.appendingPathComponent(theme.frames[index]), options: .atomic)
        }
        try JSONEncoder.themeEncoder.encode(theme)
            .write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        return theme
    }

    func loadTheme(id: UUID) -> UsageTheme? {
        let manifest = rootURL.appendingPathComponent(id.uuidString).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest) else { return nil }
        return try? JSONDecoder.themeDecoder.decode(UsageTheme.self, from: data)
    }

    func imageURL(theme: UsageTheme, frameName: String) -> URL {
        directoryURL(for: theme).appendingPathComponent(frameName)
    }

    private func directoryURL(for theme: UsageTheme) -> URL {
        rootURL.appendingPathComponent(theme.id.uuidString, isDirectory: true)
    }
}

private extension NSImage {
    var pixelSize: CGSize? {
        guard let representation = representations.first else { return nil }
        return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }

    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

private extension JSONEncoder {
    static var themeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var themeDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
