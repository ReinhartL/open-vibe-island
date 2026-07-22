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
        "references", "scripts", "tests",
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
        var seenNames: Set<String> = []
        return roots.flatMap { loadSkills(at: $0.url, source: $0.source) }
            .filter { seenNames.insert($0.name.lowercased()).inserted }
            .sorted {
                let nameOrder = $0.name.localizedStandardCompare($1.name)
                if nameOrder == .orderedSame {
                    return $0.fileURL.path.localizedStandardCompare($1.fileURL.path) == .orderedAscending
                }
                return nameOrder == .orderedAscending
            }
    }

    private func loadSkills(at root: URL, source: CodexSkill.Source) -> [CodexSkill] {
        if source == .plugin {
            return loadPluginSkills(at: root)
        }

        var skills = loadDirectSkills(at: root, source: source)
        if source == .configured {
            skills.append(contentsOf: loadDirectSkills(
                at: root.appendingPathComponent(".system", isDirectory: true),
                source: source
            ))
        }
        return skills
    }

    private func loadPluginSkills(at root: URL) -> [CodexSkill] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var skills: [CodexSkill] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard isDirectory else { continue }
            if Self.excludedDirectoryNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "skills" else { continue }
            skills.append(contentsOf: loadDirectSkills(at: url, source: .plugin))
            enumerator.skipDescendants()
        }
        return skills
    }

    private func loadDirectSkills(at root: URL, source: CodexSkill.Source) -> [CodexSkill] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        return directories.compactMap { directory in
            let skillURL = directory.appendingPathComponent("SKILL.md")
            guard let contents = try? String(contentsOf: skillURL, encoding: .utf8),
                  let metadata = Self.parseFrontMatter(contents) else { return nil }

            let name = metadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return CodexSkill(
                name: name,
                description: metadata.description.trimmingCharacters(in: .whitespacesAndNewlines),
                fileURL: skillURL,
                source: source
            )
        }
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

enum CodexSkillSearchMode: String, CaseIterable, Identifiable, Sendable {
    case prefix
    case regularExpression

    var id: String { rawValue }
}

struct CodexSkillSearch {
    let query: String
    let mode: CodexSkillSearchMode

    var isValid: Bool {
        mode != .regularExpression || regularExpression != nil
    }

    func filter(_ skills: [CodexSkill]) -> [CodexSkill] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return skills }

        switch mode {
        case .prefix:
            return skills.filter {
                $0.name.range(
                    of: value,
                    options: [.anchored, .caseInsensitive, .diacriticInsensitive]
                ) != nil
            }
        case .regularExpression:
            guard let regularExpression else { return [] }
            return skills.filter { skill in
                let range = NSRange(skill.name.startIndex..<skill.name.endIndex, in: skill.name)
                return regularExpression.firstMatch(in: skill.name, range: range) != nil
            }
        }
    }

    private var regularExpression: NSRegularExpression? {
        try? NSRegularExpression(pattern: query, options: [.caseInsensitive])
    }
}
