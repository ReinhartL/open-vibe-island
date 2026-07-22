import Foundation

struct CodexSkill: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable {
        case user
        case configured
        case plugin
        case legacy
    }

    let name: String
    let description: String
    let fileURL: URL
    let source: Source

    var id: String { fileURL.path }
    var mention: String { "$\(name)" }
    var initial: String {
        guard let character = name.first else { return "#" }
        let value = String(character).uppercased()
        return value.range(of: "^[A-Z]$", options: .regularExpression) == nil ? "#" : value
    }
}

struct CodexSkillCatalog {
    private static let excludedDirectoryNames: Set<String> = [
        ".build", ".git", "assets", "checkouts", "docs", "node_modules",
        "references", "scripts", "tests", "vendor",
    ]

    private let fileManager: FileManager
    private let roots: [(url: URL, source: CodexSkill.Source)]

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        let defaultCodexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let configuredCodexHome = environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        } ?? defaultCodexHome

        var discoveredRoots: [(url: URL, source: CodexSkill.Source)] = [
            (homeDirectory.appendingPathComponent(".agents/skills", isDirectory: true), .user),
            (configuredCodexHome.appendingPathComponent("skills", isDirectory: true), .configured),
            (configuredCodexHome.appendingPathComponent("plugins/cache", isDirectory: true), .plugin),
        ]
        if configuredCodexHome != defaultCodexHome {
            discoveredRoots.append((defaultCodexHome.appendingPathComponent("skills", isDirectory: true), .legacy))
        }
        roots = discoveredRoots
    }

    init(fileManager: FileManager = .default, roots: [(URL, CodexSkill.Source)]) {
        self.fileManager = fileManager
        self.roots = roots.map { (url: $0.0, source: $0.1) }
    }

    func load() -> [CodexSkill] {
        roots.flatMap { loadSkills(at: $0.url, source: $0.source) }.sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder == .orderedSame {
                return $0.fileURL.path.localizedStandardCompare($1.fileURL.path) == .orderedAscending
            }
            return nameOrder == .orderedAscending
        }
    }

    private func loadSkills(at root: URL, source: CodexSkill.Source) -> [CodexSkill] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var skills: [CodexSkill] = []
        for case let skillURL as URL in enumerator {
            if Self.excludedDirectoryNames.contains(skillURL.lastPathComponent),
               (try? skillURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                enumerator.skipDescendants()
                continue
            }
            guard skillURL.lastPathComponent == "SKILL.md" else { continue }
            guard let contents = try? String(contentsOf: skillURL, encoding: .utf8),
                  let metadata = Self.parseFrontMatter(contents) else { continue }

            let name = metadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            skills.append(CodexSkill(
                name: name,
                description: metadata.description.trimmingCharacters(in: .whitespacesAndNewlines),
                fileURL: skillURL,
                source: source
            ))
        }
        return skills
    }

    static func parseFrontMatter(_ contents: String) -> (name: String, description: String)? {
        let lines = contents.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let closingIndex = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
              }) else { return nil }

        let frontMatter = Array(lines[1..<closingIndex])
        guard let name = scalar(named: "name", in: frontMatter) else { return nil }
        let description = scalar(named: "description", in: frontMatter) ?? ""
        return (unquote(name), unquote(description))
    }

    private static func scalar(named key: String, in lines: [String]) -> String? {
        guard let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):")
        }) else { return nil }

        let line = lines[index].trimmingCharacters(in: .whitespaces)
        let value = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        guard value == ">" || value == "|" else { return value }

        return lines.dropFirst(index + 1)
            .prefix(while: { $0.hasPrefix(" ") || $0.hasPrefix("\t") })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: value == ">" ? " " : "\n")
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return value }
        return String(value.dropFirst().dropLast())
    }
}
