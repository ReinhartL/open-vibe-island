import AppKit
import SwiftUI

struct UsageThemeCreatorView: View {
    private enum CodexStatus: Equatable {
        case checking
        case connected
        case unavailable(String)
    }

    let model: AppModel
    let profile: IslandAppearanceDisplayProfile
    @Environment(\.dismiss) private var dismiss

    @State private var description = ""
    @State private var referenceImage: Data?
    @State private var storyboard: UsageStoryboard?
    @State private var codexStatus: CodexStatus = .checking
    @State private var isWorking = false
    @State private var status = ""
    @State private var errorMessage: String?

    private let generator = UsageThemeGenerator()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Usage Theme").font(.title2.bold())

            codexConnectionRow

            TextEditor(text: $description)
                .font(.body)
                .frame(height: 72)
                .padding(6)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Describe the character and how the whole scene changes as usage increases")
                            .foregroundStyle(.secondary).padding(12).allowsHitTesting(false)
                    }
                }

            HStack {
                Button(referenceImage == nil ? "Add reference image" : "Replace reference image") {
                    chooseReferenceImage()
                }
                if referenceImage != nil {
                    Label("Reference ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("No reference image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let storyboard {
                VStack(alignment: .leading, spacing: 7) {
                    Text(storyboard.title).font(.headline)
                    ForEach(Array(storyboard.stages.enumerated()), id: \.offset) { _, stage in
                        Text("\(stage.usageRange)% · \(stage.action) · \(stage.emotion)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }

            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }

            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if storyboard == nil {
                    Button("Generate storyboard") { Task { await generateStoryboard() } }
                        .disabled(
                            isWorking ||
                            description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            codexStatus != .connected
                        )
                } else {
                    Button("Generate four frames") { Task { await generateFrames() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking || codexStatus != .connected)
                }
            }
        }
        .padding(22)
        .frame(width: 580, height: 500)
        .task { await checkCodexConnection() }
    }

    @ViewBuilder
    private var codexConnectionRow: some View {
        HStack(spacing: 8) {
            switch codexStatus {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking your Codex CLI connection…")
            case .connected:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Using your current Codex CLI account")
            case .unavailable(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(2)
                Spacer()
                Button {
                    Task { await checkCodexConnection() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Check Codex again")
            }
        }
        .font(.caption)
        .foregroundStyle(codexStatus == .connected ? .primary : .secondary)
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
    }

    private func chooseReferenceImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { referenceImage = try Data(contentsOf: url); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func checkCodexConnection() async {
        codexStatus = .checking
        do {
            try await generator.checkCodexConnection()
            codexStatus = .connected
        } catch {
            codexStatus = .unavailable(error.localizedDescription)
        }
    }

    private func generateStoryboard() async {
        await perform("Asking Codex for a four-stage storyboard…") {
            storyboard = try await generator.createStoryboard(description: description)
        }
    }

    private func generateFrames() async {
        guard let storyboard else { return }
        await perform("Codex is generating four character-consistent frames…") {
            let frames = try await generator.generateFrames(
                description: description,
                storyboard: storyboard,
                referenceImage: referenceImage
            )
            let theme = try UsageThemeStore().importTheme(name: storyboard.title, imageData: frames)
            model.selectedUsageTheme = theme
            UserDefaults.standard.set(theme.id.uuidString, forKey: UsageThemeStore.selectedThemeDefaultsKey)
            model.updateAppearancePreferences(for: profile) { $0.usageDisplay = .animated }
            dismiss()
        }
    }

    private func perform(_ message: String, operation: () async throws -> Void) async {
        isWorking = true
        status = message
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await operation()
            status = "Ready"
        } catch {
            errorMessage = error.localizedDescription
            status = ""
        }
    }
}
