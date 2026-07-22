import Foundation
import Testing
@testable import OpenIslandApp

struct CodexSkillCatalogTests {
    @Test
    func loadsNestedSkillsAndPreservesDuplicateNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current")
        let legacy = root.appendingPathComponent("legacy")

        try writeSkill(named: "review", description: "Review a change", under: current)
        try writeSkill(named: "build", description: "Build the app", under: current.appendingPathComponent("plugin/skills"))
        try writeSkill(named: "review", description: "Old review", under: legacy)

        let skills = CodexSkillCatalog(roots: [(current, .user), (legacy, .legacy)]).load()

        #expect(skills.map(\.name) == ["build", "review", "review"])
        #expect(skills.filter { $0.name == "review" }.map(\.source) == [.user, .legacy])
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
}
