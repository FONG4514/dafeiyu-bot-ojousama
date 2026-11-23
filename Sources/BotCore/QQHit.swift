import Foundation

/// Code-owned hit counter. The model never decides the window or the faint.
public struct QQHitClock: Equatable, Sendable {
    public static let window: TimeInterval = 180
    public static let faintDuration: TimeInterval = 60
    public static let faintReply = "[晕倒惹，晕乎乎]"
    public private(set) var hits: [Date] = []
    public private(set) var faintUntil: Date?
    public init() {}

    public func isFainted(at now: Date) -> Bool {
        guard let faintUntil else { return false }
        return now < faintUntil
    }

    public enum Outcome: Equatable, Sendable {
        case dizzy(Int)
        case faint
    }

    /// Counts one hit. Five hits inside three minutes start a one-minute faint.
    public mutating func hit(at now: Date) -> Outcome {
        if let faintUntil, now >= faintUntil { self.faintUntil = nil; hits.removeAll() }
        hits.removeAll { now.timeIntervalSince($0) >= Self.window }
        hits.append(now)
        if hits.count >= 5 {
            faintUntil = now.addingTimeInterval(Self.faintDuration)
            hits.removeAll()
            return .faint
        }
        return .dizzy(hits.count)
    }

    /// Text after `/欺负`. `nil` means this is not the command. `/hit` is not this command.
    public static func rest(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = value.range(of: #"^/欺负(?=$|\s)"#, options: .regularExpression) else { return nil }
        let rest = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard rest.count <= 20, rest.range(of: #"[\r\n]"#, options: .regularExpression) == nil else { return nil }
        return rest
    }
    public static func matches(_ text: String) -> Bool {
        guard let rest = rest(text) else { return false }
        return rest.isEmpty || rest == "打一下"
    }
    public static let bullyFaintReply = "[打晕惹]"
    /// The bot is hitting a marked person. The count still belongs to the program.
    public static func bullyInstruction(count: Int, name: String) -> String {
        let step = min(4, max(1, count))
        let degree = ["刚挨到，还站得住。", "比上一句更晕，开始晃。", "站不稳，眼前发花。", "快倒下，但这一下还没晕。"][step - 1]
        return "程序已经点清：这是三分钟窗口内欺负 \(name) 的第 \(step) 下。你在欺负\(name)，不是自己挨打。次数和时间都由程序统计，你不能改次数，也不能判断要不要把对方打晕。第 5 下和随后一分钟由程序自己回复，这一下不要写打晕。这句话只使用触发这条命令的人的当前生效性格，不要改用被欺负的人的性格、态度或口吻。只写一句短话：\(degree)"
    }

    /// The model only writes the sentence. It must not recount hits or decide the faint.
    public static func modelInstruction(count: Int) -> String {
        let step = min(4, max(1, count))
        let degree = ["刚被打到，还站得住，只带一点晕。", "比上一句更晕，开始晃。", "站不稳，眼前发花。", "快倒下，但这一下还没晕倒。"][step - 1]
        return "程序已经点清：这是三分钟窗口内的第 \(step) 下。你自己挨打，不是在打别人。次数和时间都由程序统计，你不能改次数，也不能判断要不要晕倒。第 5 下和随后一分钟由程序自己回复，这一下不要写晕倒。只用被接话的人的应对性格写一句短话，不要改用其他人的态度：\(degree)"
    }
}
