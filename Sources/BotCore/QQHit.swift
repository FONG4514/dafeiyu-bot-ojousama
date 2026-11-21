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

    public static func matches(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = value.range(of: #"^/hit(?=$|\s)"#, options: [.regularExpression, .caseInsensitive]) else { return false }
        let rest = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty || rest == "打一下"
    }

    /// The model only writes the sentence. It must not recount hits or decide the faint.
    public static func modelInstruction(count: Int) -> String {
        let step = min(4, max(1, count))
        let degree = ["刚被打到，还站得住，只带一点晕。", "比上一句更晕，开始晃。", "站不稳，眼前发花。", "快倒下，但这一下还没晕倒。"][step - 1]
        return "程序已经点清：这是三分钟窗口内的第 \(step) 下。次数和时间都由程序统计，你不能改次数，也不能判断要不要晕倒。第 5 下和随后一分钟由程序自己回复，这一下不要写晕倒。只按当前人设写一句短话：\(degree)"
    }
}
