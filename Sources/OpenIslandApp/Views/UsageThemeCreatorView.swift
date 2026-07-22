import AppKit
import SwiftUI

struct UsageThemeCreatorView: View {
    let model: AppModel
    let profile: IslandAppearanceDisplayProfile
    @Environment(\.dismiss) private var dismiss

    @State private var description = ""
    @State private var apiKey = ""
    @State private var referenceImage: Data?
    @State private var storyboard: UsageStoryboard?
    @State private var isWorking = false
    @State private var status = ""
    @State private var errorMessage: String?

    private let generator = UsageThemeGenerator()
    private let keyStore = OpenAIAPIKeyStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Usage Theme").font(.title2.bold())

            SecureField("OpenAI API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $description)
                .font(.body)
                .frame(height: 72)
                .padding(6)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Describe the character and how the scene changes as usage increases")
                            .foregroundStyle(.secondary).padding(12).allowsHitTesting(false)
                    }
                }

            HStack {
                Button(referenceImage == nil ? "Add reference image" : "Replace reference image") {
                    chooseReferenceImage()
                }
                if referenceImage != nil {
                    Label("Reference ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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
                        .disabled(isWorking || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKey.isEmpty)
                } else {
                    Button("Generate four frames") { Task { await generateFrames() } }
                        .buttonStyle(.borderedProminent).disabled(isWorking)
                }
            }
        }
        .padding(22)
        .frame(width: 560, height: 480)
        .onAppear { apiKey = keyStore.load() ?? "" }
    }

    private func chooseReferenceImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { referenceImage = try Data(contentsOf: url); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func generateStoryboard() async {
        await perform("Generating four-stage storyboard…") {
            try keyStore.save(apiKey)
            storyboard = try await generator.createStoryboard(description: description, apiKey: apiKey)
        }
    }

    private func generateFrames() async {
        guard let storyboard else { return }
        await perform("Generating character-consistent frames…") {
            let reference: Data
            if let referenceImage {
                reference = referenceImage
            } else {
                reference = try await generator.generateReference(
                    description: description, storyboard: storyboard, apiKey: apiKey
                )
            }
            let frames = try await generator.generateFrames(
                description: description, storyboard: storyboard, referenceImage: reference, apiKey: apiKey
            )
            let theme = try UsageThemeStore().importTheme(name: storyboard.title, imageData: frames)
            model.selectedUsageTheme = theme
            UserDefaults.standard.set(theme.id.uuidString, forKey: UsageThemeStore.selectedThemeDefaultsKey)
            model.updateAppearancePreferences(for: profile) { $0.usageDisplay = .animated }
            dismiss()
        }
    }

    private func perform(_ message: String, operation: () async throws -> Void) async {
        isWorking = true; status = message; errorMessage = nil
        defer { isWorking = false }
        do { try await operation(); status = "Ready" }
        catch { errorMessage = error.localizedDescription; status = "" }
    }
}
