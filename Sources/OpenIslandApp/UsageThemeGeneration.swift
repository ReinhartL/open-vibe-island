import Foundation
import Security

struct UsageStoryboard: Codable, Equatable, Sendable {
    struct Stage: Codable, Equatable, Sendable {
        let usageRange: String
        let action: String
        let emotion: String
    }

    let title: String
    let characterInvariants: [String]
    let stages: [Stage]

    var isValid: Bool { stages.count == UsageTheme.frameCount && !characterInvariants.isEmpty }
}

enum UsageThemeGenerationError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case invalidStoryboard
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Enter an OpenAI API key before generating a theme."
        case .invalidResponse: "The image service returned an invalid response."
        case .invalidStoryboard: "The generated storyboard did not contain four valid stages."
        case .requestFailed(let message): message
        }
    }
}

struct OpenAIAPIKeyStore {
    private static let service = "app.openisland.usage-themes"
    private static let account = "openai-api-key"

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw UsageThemeGenerationError.requestFailed("Could not save the API key in Keychain.")
            }
        } else if status != errSecSuccess {
            throw UsageThemeGenerationError.requestFailed("Could not update the API key in Keychain.")
        }
    }
}

struct UsageThemeGenerator {
    var session: URLSession = .shared
    var baseURL = URL(string: "https://api.openai.com/v1")!

    func createStoryboard(description: String, apiKey: String) async throws -> UsageStoryboard {
        let prompt = """
        Convert this usage-theme idea into exactly four progressive narrative stages: \(description)

        Return JSON only with keys title, characterInvariants, and stages. Each stage has usageRange,
        action, and emotion. Ranges must be 0-24, 25-49, 50-74, 75-100. Preserve character identity,
        art style, proportions, colors, clothing, and accessories. Expressions, poses, actions, props,
        and effects should change meaningfully. No text or watermarks may appear in generated images.
        """
        let body: [String: Any] = [
            "model": "gpt-5.6-sol",
            "input": prompt,
            "text": ["format": ["type": "json_object"]],
        ]
        let data = try await jsonRequest(path: "responses", body: body, apiKey: apiKey)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? [[String: Any]] else {
            throw UsageThemeGenerationError.invalidStoryboard
        }
        let content = output.compactMap { $0["content"] as? [[String: Any]] }.flatMap { $0 }
        guard
              let text = content.first(where: { $0["type"] as? String == "output_text" })?["text"] as? String,
              let storyboardData = text.data(using: .utf8),
              let storyboard = try? JSONDecoder().decode(UsageStoryboard.self, from: storyboardData),
              storyboard.isValid else { throw UsageThemeGenerationError.invalidStoryboard }
        return storyboard
    }

    func generateReference(description: String, storyboard: UsageStoryboard, apiKey: String) async throws -> Data {
        let prompt = """
        Create a square character reference image for a four-stage usage animation theme.
        User idea: \(description). Character rules: \(storyboard.characterInvariants.joined(separator: ", ")).
        Show the character clearly in the requested art style, centered with generous margins.
        No text, labels, grid, border, watermark, or extra characters.
        """
        return try await generateImage(prompt: prompt, apiKey: apiKey)
    }

    func generateFrames(
        description: String,
        storyboard: UsageStoryboard,
        referenceImage: Data,
        apiKey: String
    ) async throws -> [Data] {
        var frames: [Data] = []
        for stage in storyboard.stages {
            let prompt = """
            Create one square frame for a four-stage usage animation. Use the supplied image as the
            immutable character identity and style reference. User idea: \(description).
            Preserve exactly: \(storyboard.characterInvariants.joined(separator: ", ")).
            Stage \(stage.usageRange)%: action is \(stage.action); emotion is \(stage.emotion).
            Expressions, pose, interaction, and prop state should clearly communicate this stage.
            Keep framing and character scale consistent across all stages. No text, labels, grid,
            border, watermark, or additional characters.
            """
            frames.append(try await editImage(referenceImage, prompt: prompt, apiKey: apiKey))
        }
        return frames
    }

    private func generateImage(prompt: String, apiKey: String) async throws -> Data {
        let body: [String: Any] = ["model": "gpt-image-2", "prompt": prompt, "size": "1024x1024"]
        let data = try await jsonRequest(path: "images/generations", body: body, apiKey: apiKey)
        return try decodeImage(data)
    }

    private func editImage(_ image: Data, prompt: String, apiKey: String) async throws -> Data {
        let boundary = "OpenIsland-\(UUID().uuidString)"
        var body = Data()
        body.appendFormField("model", value: "gpt-image-2", boundary: boundary)
        body.appendFormField("prompt", value: prompt, boundary: boundary)
        body.appendFormFile("image[]", filename: "reference.png", contentType: "image/png", data: image, boundary: boundary)
        body.append("--\(boundary)--\r\n")

        var request = URLRequest(url: baseURL.appendingPathComponent("images/edits"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try decodeImage(try await send(request))
    }

    private func jsonRequest(path: String, body: [String: Any], apiKey: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
            throw UsageThemeGenerationError.requestFailed(message ?? "Image generation request failed.")
        }
        return data
    }

    private func decodeImage(_ data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = object["data"] as? [[String: Any]],
              let encoded = images.first?["b64_json"] as? String,
              let image = Data(base64Encoded: encoded) else { throw UsageThemeGenerationError.invalidResponse }
        return image
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
    mutating func appendFormField(_ name: String, value: String, boundary: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }
    mutating func appendFormFile(_ name: String, filename: String, contentType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n")
        append(data)
        append("\r\n")
    }
}
