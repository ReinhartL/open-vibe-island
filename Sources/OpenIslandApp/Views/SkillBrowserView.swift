import AppKit
import SwiftUI

struct SkillBrowserView: View {
    let model: AppModel

    @State private var skills: [CodexSkill] = []
    @State private var query = ""
    @State private var searchMode: CodexSkillSearchMode = .prefix
    @State private var hoveredSkill: CodexSkill?
    @State private var copiedSkillID: String?
    @FocusState private var searchFocused: Bool

    private let catalog = CodexSkillCatalog()
    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 10, alignment: .top),
    ]

    private var lang: LanguageManager { model.lang }

    private var filteredSkills: [CodexSkill] {
        search.filter(skills)
    }

    private var search: CodexSkillSearch { CodexSkillSearch(query: query, mode: searchMode) }

    private var groups: [(initial: String, skills: [CodexSkill])] {
        Dictionary(grouping: filteredSkills, by: \.initial)
            .map { (initial: $0.key, skills: $0.value) }
            .sorted { lhs, rhs in
                if lhs.initial == "#" { return false }
                if rhs.initial == "#" { return true }
                return lhs.initial < rhs.initial
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HSplitView {
                skillGrid
                    .frame(minWidth: 500)
                inspector
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 290)
            }
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 540, idealHeight: 640)
        .preferredColorScheme(.dark)
        .onAppear {
            reload()
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reload()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 2) {
                Text(lang.t("skills.title"))
                    .font(.headline)
                Text(String(format: lang.t("skills.count"), filteredSkills.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)

            Picker(lang.t("skills.searchMode"), selection: $searchMode) {
                Text(lang.t("skills.searchMode.prefix")).tag(CodexSkillSearchMode.prefix)
                Text(lang.t("skills.searchMode.regex")).tag(CodexSkillSearchMode.regularExpression)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 138)

            TextField(
                searchMode == .prefix ? lang.t("skills.search.prefix") : lang.t("skills.search.regex"),
                text: $query
            )
            .textFieldStyle(.roundedBorder)
            .focused($searchFocused)
            .overlay {
                if !search.isValid {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(0.85), lineWidth: 1)
                }
            }
            .frame(width: 260)

            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(lang.t("skills.refresh"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var skillGrid: some View {
        if skills.isEmpty {
            ContentUnavailableView(
                lang.t("skills.empty.title"),
                systemImage: "square.stack.3d.up.slash",
                description: Text(lang.t("skills.empty.description"))
            )
        } else if !search.isValid {
            ContentUnavailableView(
                lang.t("skills.regex.invalid.title"),
                systemImage: "exclamationmark.triangle",
                description: Text(lang.t("skills.regex.invalid.description"))
            )
        } else if filteredSkills.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.initial) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.initial)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                                ForEach(group.skills) { skill in
                                    SkillTile(
                                        skill: skill,
                                        isHovered: hoveredSkill?.id == skill.id,
                                        isCopied: copiedSkillID == skill.id
                                    ) {
                                        copy(skill)
                                    }
                                    .onHover { isHovered in
                                        if isHovered {
                                            hoveredSkill = skill
                                        } else if hoveredSkill?.id == skill.id {
                                            hoveredSkill = nil
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let skill = hoveredSkill {
                HStack(alignment: .top) {
                    Image(systemName: "sparkle")
                        .foregroundStyle(.cyan)
                    Text(skill.name)
                        .font(.headline)
                        .textSelection(.enabled)
                }

                Text(skill.description.isEmpty ? lang.t("skills.noDescription") : skill.description)
                    .font(.callout)
                    .foregroundStyle(skill.description.isEmpty ? .tertiary : .secondary)
                    .textSelection(.enabled)

                Divider()

                Label(sourceLabel(for: skill.source), systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.tertiary)

                Spacer()

                Text(lang.t("skills.clickToCopy"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text(lang.t("skills.hoverHint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(18)
    }

    private func reload() {
        skills = catalog.load()
        if let hoveredSkill,
           !skills.contains(where: { $0.id == hoveredSkill.id }) {
            self.hoveredSkill = nil
        }
    }

    private func copy(_ skill: CodexSkill) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(skill.mention, forType: .string)
        copiedSkillID = skill.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedSkillID == skill.id {
                copiedSkillID = nil
            }
        }
    }

    private func sourceLabel(for source: CodexSkill.Source) -> String {
        switch source {
        case .user: lang.t("skills.source.user")
        case .configured: lang.t("skills.source.configured")
        case .plugin: lang.t("skills.source.plugin")
        case .legacy: lang.t("skills.source.legacy")
        }
    }
}

struct SkillTile: View {
    let skill: CodexSkill
    let isHovered: Bool
    let isCopied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isCopied ? "checkmark" : "sparkle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCopied ? .green : .cyan)
                    .frame(width: 20, height: 20)

                Text(skill.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: .leading)
            .background(isHovered ? Color.white.opacity(0.10) : Color.white.opacity(0.055))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isHovered ? Color.cyan.opacity(0.65) : Color.white.opacity(0.08))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(skill.description)
    }
}
