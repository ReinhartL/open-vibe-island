import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OpenIslandApp

struct CodexSkillCatalogTests {
    @Test
    func loadsOnlyParentSkillsAndDeduplicatesNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current")
        let legacy = root.appendingPathComponent("legacy")

        try writeSkill(named: "review", description: "Review a change", under: current)
        try writeSkill(named: "build", description: "Build the app", under: current.appendingPathComponent("plugin/skills"))
        try writeSkill(named: "review", description: "Old review", under: legacy)

        let skills = CodexSkillCatalog(roots: [(current, .user), (legacy, .legacy)]).load()

        #expect(skills.map(\.name) == ["review"])
        #expect(skills.first?.source == .user)
    }

    @Test
    func parsesQuotedAndFoldedFrontMatter() {
        let contents = """
        ---
        name: "release-helper"
        description: >
          Prepare a release and
          verify its artifacts.
        ---
        Instructions follow.
        """

        let metadata = CodexSkillCatalog.parseFrontMatter(contents)

        #expect(metadata?.name == "release-helper")
        #expect(metadata?.description == "Prepare a release and verify its artifacts.")
    }

    @Test
    func honorsConfiguredCodexHomeAndPluginCache() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let configuredHome = home.appendingPathComponent("custom-codex")

        try writeSkill(named: "personal", description: "Personal skill", under: home.appendingPathComponent(".agents/skills"))
        try writeSkill(named: "built-in", description: "Configured skill", under: configuredHome.appendingPathComponent("skills"))
        try writeSkill(named: "browser", description: "Plugin skill", under: configuredHome.appendingPathComponent("plugins/cache/browser/skills"))
        try writeSkill(named: "legacy", description: "Legacy skill", under: home.appendingPathComponent(".codex/skills"))

        let skills = CodexSkillCatalog(
            homeDirectory: home,
            environment: ["CODEX_HOME": configuredHome.path]
        ).load()

        #expect(skills.map(\.name) == ["browser", "built-in", "legacy", "personal"])
        #expect(skills.map(\.source) == [.plugin, .configured, .legacy, .user])
    }

    @Test
    func pluginCacheLoadsOnlyDirectChildrenOfSkillsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginCache = root.appendingPathComponent("plugins/cache")
        let pluginSkills = pluginCache.appendingPathComponent("vendor/browser/1.0.0/skills")

        try writeSkill(named: "browser", description: "Browse pages", under: pluginSkills)
        try writeSkill(named: "browser-helper", description: "Internal helper", under: pluginSkills.appendingPathComponent("browser/skills"))

        let skills = CodexSkillCatalog(roots: [(pluginCache, .plugin)]).load()

        #expect(skills.map(\.name) == ["browser"])
    }

    @Test
    func prefixSearchMatchesNamesOnlyFromTheBeginning() {
        let skills = [
            skill(named: "autoplan", description: "Build a plan"),
            skill(named: "browser", description: "Browse pages"),
            skill(named: "benchmark", description: "Measure performance"),
            skill(named: "web-clone", description: "Clone a site"),
        ]

        let results = CodexSkillSearch(query: "b", mode: .prefix).filter(skills)

        #expect(results.map(\.name) == ["browser", "benchmark"])
    }

    @Test
    func regularExpressionSearchMatchesNamesAndReportsInvalidPatterns() {
        let skills = [
            skill(named: "browser", description: "Browse pages"),
            skill(named: "benchmark", description: "Measure performance"),
            skill(named: "build-web-apps", description: "Build apps"),
        ]
        let search = CodexSkillSearch(query: "^b.*(er|mark)$", mode: .regularExpression)
        let invalidSearch = CodexSkillSearch(query: "[", mode: .regularExpression)

        #expect(search.isValid)
        #expect(search.filter(skills).map(\.name) == ["browser", "benchmark"])
        #expect(!invalidSearch.isValid)
        #expect(invalidSearch.filter(skills).isEmpty)
    }

    @Test
    func derivesMentionAndAlphabeticGroup() {
        let skill = CodexSkill(
            name: "review",
            description: "Review changes",
            fileURL: URL(fileURLWithPath: "/tmp/review/SKILL.md"),
            source: .user
        )

        #expect(skill.mention == "$review")
        #expect(skill.initial == "R")
    }

    @MainActor
    @Test
    func copiedSkillTileKeepsItsIntrinsicWidth() {
        let skill = CodexSkill(
            name: "long-skill-name-that-wraps",
            description: "Test skill",
            fileURL: URL(fileURLWithPath: "/tmp/long-skill/SKILL.md"),
            source: .user
        )
        let idle = NSHostingView(rootView: SkillTile(
            skill: skill,
            isHovered: false,
            isCopied: false,
            action: {}
        ))
        let copied = NSHostingView(rootView: SkillTile(
            skill: skill,
            isHovered: false,
            isCopied: true,
            action: {}
        ))

        #expect(abs(idle.fittingSize.width - copied.fittingSize.width) < 0.5)
    }

    private func writeSkill(named name: String, description: String, under root: URL) throws {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = """
        ---
        name: \(name)
        description: \(description)
        ---
        """
        try contents.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private func skill(named name: String, description: String) -> CodexSkill {
        CodexSkill(
            name: name,
            description: description,
            fileURL: URL(fileURLWithPath: "/tmp/\(name)/SKILL.md"),
            source: .user
        )
    }
}
