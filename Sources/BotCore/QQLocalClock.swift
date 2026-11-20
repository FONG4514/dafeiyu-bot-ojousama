import Foundation

/// Pulls a reply JSON object out of reasoning when the model left `content` empty.
public enum QQReplyText {
    public static func jsonObject(in reasoning: String?) -> String? {
        guard let reasoning, let start = reasoning.firstIndex(of: "{"), let end = reasoning.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(reasoning[start...end])
        guard slice.utf8.count <= 8000, let data = slice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return slice
    }
}


/// Local clock facts for a turn that asks the time or date. No city, path, or account.
public enum QQLocalClock {
    public static func asks(_ text: String) -> Bool {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let patterns = [
            "现在几点", "几点了", "几点钟", "什么时间", "现在时间", "当前时间", "此刻几点",
            "今天几号", "今天多少号", "今天日期", "今天星期", "星期几", "周几", "几月几号", "今天是几",
            "what time", "what's the time", "whats the time", "what day", "today's date", "todays date"
        ]
        return patterns.contains { folded.contains($0) }
    }
    public static func prompt(now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss EEEE"
        let seconds = calendar.timeZone.secondsFromGMT(for: now)
        let sign = seconds >= 0 ? "+" : "-"
        let magnitude = abs(seconds)
        let offset = String(format: "%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
        return "本机时钟（每次回复前由程序透传，不是记忆，不要写入记忆，不要联网，不要猜测，不要提及城市、路径或账号）：本地时间 \(formatter.string(from: now))，时区偏移 \(offset)。对方问时间或日期时只根据这段回答；其他时候不必主动报时。"
    }
}
