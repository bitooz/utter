import Foundation

/// OpenRouter calls outside dictation: checking a key, and listing the models that take audio.
public enum OpenRouter {
    public struct KeyInfo: Sendable {
        public var label: String?
        /// Credit left on the key, if it has a limit.
        public var remaining: Double?
        public var freeTier: Bool
    }

    public enum CheckError: Error, CustomStringConvertible {
        case rejected, offline(String), unexpected(Int)
        public var description: String {
            switch self {
            case .rejected: return "OpenRouter doesn't accept this key."
            case .offline(let why): return "Couldn't reach OpenRouter: \(why)"
            case .unexpected(let code): return "OpenRouter answered \(code)."
            }
        }
    }

    /// Asks OpenRouter whether the key works.
    public static func check(key: String) async throws -> KeyInfo {
        var r = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        r.setValue("Bearer \(key.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 10
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: r) } catch { throw CheckError.offline(error.localizedDescription) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw CheckError.rejected }
        guard status == 200 else { throw CheckError.unexpected(status) }
        let d = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [String: Any] ?? [:]
        return KeyInfo(label: d["label"] as? String, remaining: d["limit_remaining"] as? Double,
                       freeTier: d["is_free_tier"] as? Bool ?? false)
    }

    public struct ModelInfo: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        /// Dollars per million input tokens.
        public var pricePerMillion: Double?
        /// Dollars per million audio input tokens, when OpenRouter lists it separately.
        public var audioPricePerMillion: Double?
        public var contextLength: Int?
    }

    static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Utter/audio-models.json")

    /// Models from the last successful fetch (empty before the first).
    public static func cachedAudioModels() -> [ModelInfo] {
        guard let d = try? Data(contentsOf: cacheURL), let list = try? JSONDecoder().decode([ModelInfo].self, from: d) else { return [] }
        remember(list)
        return list
    }

    /// Every model on OpenRouter that takes audio input, Gemini first, newest first within a family.
    public static func audioModels() async throws -> [ModelInfo] {
        var r = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        r.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: r)
        guard let all = ((try JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [[String: Any]] else {
            throw CheckError.unexpected(0)
        }
        var list: [(ModelInfo, Double)] = []
        for m in all {
            guard let id = m["id"] as? String, !id.hasSuffix(":batch"), !id.hasPrefix("openrouter/"),
                  let arch = m["architecture"] as? [String: Any],
                  (arch["input_modalities"] as? [String])?.contains("audio") == true else { continue }
            var name = (m["name"] as? String) ?? id
            if let colon = name.firstIndex(of: ":") { name = String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
            let price = ((m["pricing"] as? [String: Any])?["prompt"] as? String).flatMap(Double.init).map { $0 * 1_000_000 }
            let pricing = m["pricing"] as? [String: Any]
            let audioPrice = (pricing?["audio"] as? String).flatMap(Double.init).map { $0 * 1_000_000 }
            list.append((ModelInfo(id: id, name: name, pricePerMillion: price, audioPricePerMillion: audioPrice,
                                   contextLength: m["context_length"] as? Int), (m["created"] as? Double) ?? 0))
        }
        let sorted = list.sorted { a, b in
            let ga = a.0.id.contains("gemini"), gb = b.0.id.contains("gemini")
            if ga != gb { return ga }
            return a.1 != b.1 ? a.1 > b.1 : a.0.id < b.0.id
        }.map(\.0)
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(sorted).write(to: cacheURL)
        remember(sorted)
        return sorted
    }

    private static func remember(_ list: [ModelInfo]) {
        var names = Model.knownNames
        for m in list { names[m.id] = m.name }
        Model.knownNames = names
    }
}
