import Foundation

public enum QQMemoryMode: String, Codable, Sendable {
    case superMemory = "super"
    case balanced
    case fast
    public var storesEvents: Bool { self != .fast }
    public var snapshotSeconds: Double { self == .superMemory ? 4 : 20 }
    /// Learning thresholds. Super and fast ignore the panel cadence; balanced uses it.
    public func trigger(base: QQMemoryOptions, superLimited: Bool) -> (messages: Int, characters: Int, minutes: Int) {
        switch self {
        case .superMemory where !superLimited: return (8, .max, 4)
        case .fast: return (200, .max, 240)
        default: return (base.messageThreshold, base.characterThreshold, base.intervalMinutes)
        }
    }
}

public enum QQMemoryCategory {
    public static func fallback(kind: String) -> String {
        switch kind {
        case "preference": return "偏好"
        case "fact": return "资料"
        case "task": return "约定"
        case "event": return "经历"
        case "episode": return "对话片段"
        default: return "旧摘要"
        }
    }
    /// Empty input is valid. A bad name makes the whole value nil so the batch is rejected.
    public static func checked(_ names: [String]) -> [String]? {
        guard names.count <= 3 else { return nil }
        var result: [String] = []
        for name in names {
            guard let normalized = normalize(name), !result.contains(normalized) else { return nil }
            result.append(normalized)
        }
        return result
    }
    public static func normalize(_ raw: String) -> String? {
        let folded = raw.unicodeScalars.map { scalar -> Character in
            guard (0xFF01...0xFF5E).contains(scalar.value) else { return Character(scalar) }
            return Character(UnicodeScalar(scalar.value - 0xFEE0)!)
        }
        let name = String(folded).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (2...12).contains(name.count), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 10 || $0.value == 13 }),
              name.range(of: #"\d{5,}|https?://"#, options: .regularExpression) == nil else { return nil }
        return name
    }
    /// Keep an existing category when this user already has 64 and the name is new.
    public static func fit(_ requested: [String], existing: [String]) -> [String] {
        let known = existing
        return requested.map { name in
            if known.contains(name) || known.count < 64 { return name }
            let folded = QQMemoryIndex.terms(name)
            let nearest = known.max { QQMemoryIndex.terms($0).intersection(folded).count < QQMemoryIndex.terms($1).intersection(folded).count }
            return (nearest.flatMap { QQMemoryIndex.terms($0).intersection(folded).isEmpty ? nil : $0 }) ?? "其他"
        }
    }
}

public enum QQMemoryRank {
    public static func recency(last: Date, now: Date) -> Double {
        1 / (1 + max(0, now.timeIntervalSince(last)) / (7 * 86400))
    }
    public static func frequency(_ count: Int) -> Double { min(1, log2(1 + Double(max(0, count))) / 4) }
    public static func score(lexical: Double, last: Date, mentions: Int, importance: Int, requestedCategory: Bool, now: Date) -> Double {
        lexical + 0.6 * recency(last: last, now: now) + 0.4 * frequency(mentions) + 0.15 * Double(importance) + (requestedCategory ? 0.5 : 0)
    }
    public static func categoryHeat(last: Date, mentions: Int, now: Date) -> Double {
        0.6 * recency(last: last, now: now) + 0.4 * frequency(mentions)
    }
}

public enum QQMemoryRecall {
    public struct Request: Equatable, Sendable { public var categories: [String]; public var query: String; public var history: Bool }
    /// `nil` means the chat id did not match, so nothing may be read.
    public static func parse(_ arguments: String, expectedChat: String) -> Request? {
        guard arguments.utf8.count <= 2000, let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              let chat = object["chat"] as? String, chat == expectedChat else { return nil }
        let categories = (object["categories"] as? [String] ?? []).prefix(3).map { String($0.prefix(12)) }
        let query = String(((object["query"] as? String) ?? "").prefix(50))
        guard query.range(of: #"[\r\n]"#, options: .regularExpression) == nil else { return nil }
        return Request(categories: Array(categories), query: query, history: object["include_history"] as? Bool ?? false)
    }
}
