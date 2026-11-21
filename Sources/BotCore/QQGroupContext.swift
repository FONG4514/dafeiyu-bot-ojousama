import Foundation

/// One immutable group timeline ending at the admitted trigger, shared by direct and proactive replies.
public struct QQGroupContext: Sendable {
    private let events: [QQMemoryEvent]
    private let messages: [String: QQIncoming]
    private let account: String
    private let ignoredEventIDs: Set<String>
    public let recentImages: [(label: String, images: [QQIncomingImage])]
    public let hasUnansweredText: Bool
    public let hasRecentMedia: Bool

    public init?(events: [QQMemoryEvent], through id: String, messages: [String: QQIncoming] = [:], account: String = "", ignoredSenders: Set<String> = []) {
        guard let anchor = events.firstIndex(where: { $0.id == id }) else { return nil }
        let end = events[anchor].at
        let ordered = events.prefix(through: anchor).enumerated()
            .filter { $0.element.at <= end }
            .sorted { $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at }
            .map(\.element)
        var selected: [QQMemoryEvent] = [], previous = end
        for event in ordered.reversed() {
            // Sparse messages must not keep a conversation from an hour ago alive.
            guard end.timeIntervalSince(event.at) <= 30 * 60,
                  previous.timeIntervalSince(event.at) <= 10 * 60, selected.count < 32 else { break }
            selected.append(event); previous = event.at
        }
        self.events = selected.reversed()
        let scopedMessages = messages.filter { key, _ in selected.contains { $0.id == key } }
        self.messages = scopedMessages
        self.account = account
        let targetKey = scopedMessages.values.first?.key ?? ""
        let ignoredSubjects = Set(ignoredSenders.flatMap { sender -> [String] in
            var result = [sender]
            if !account.isEmpty && !targetKey.isEmpty {
                result.append(QQMemoryBook.subject(account: account, target: targetKey, sender: sender))
            }
            return result
        })
        let ignoredIDs = Set(selected.filter { event in
            if let sender = scopedMessages[event.id]?.sender, ignoredSenders.contains(sender) { return true }
            return ignoredSubjects.contains(event.subject)
        }.map(\.id))
        self.ignoredEventIDs = ignoredIDs
        // Only recent admitted attachments; never fetch arbitrary history or revive an old media topic.
        var imageCount = 0
        var attachments: [(label: String, images: [QQIncomingImage])] = []
        for event in selected.prefix(8) where end.timeIntervalSince(event.at) <= 180 && event.subject != "BOT" && !ignoredIDs.contains(event.id) {
            guard let message = self.messages[event.id], !message.images.isEmpty, imageCount < 3 else { continue }
            let images = Array(message.images.prefix(3 - imageCount)); imageCount += images.count
            attachments.append(("群消息 " + event.id + "，发言者 " + event.subject, images))
        }
        recentImages = attachments.reversed()
        hasRecentMedia = selected.prefix(3).contains { event in
            event.subject != "BOT" && !ignoredIDs.contains(event.id) && (scopedMessages[event.id]?.images.isEmpty == false ||
                event.text.contains("（对方发来图片或表情包") || event.text.contains("（群成员发送了媒体或卡片"))
        }
        let sinceReply = self.events.lastIndex(where: { $0.subject == "BOT" }).map { $0 + 1 } ?? 0
        hasUnansweredText = self.events.dropFirst(sinceReply).contains { event in
            event.subject != "BOT" && !ignoredIDs.contains(event.id) && !Self.readableText(event.text).isEmpty
        }
    }

    public func context(characters: Int) -> String {
        var lines: [String] = [], used = 0
        let formatter = ISO8601DateFormatter()
        for event in events.reversed() {
            let text = Self.readableText(event.text)
            let speaker = event.subject == "OWNER" ? "[OWNER] 本账号主人/开发者的人工发言" : event.subject
            var fields = ["message": event.id, "time": formatter.string(from: event.at), "speaker": speaker,
                          "text": text.isEmpty ? "[媒体/表情未读取，不猜测画面或情绪]" : String(text.prefix(500))]
            if ignoredEventIDs.contains(event.id) {
                fields["filtered"] = "忽略名单发言，仅作时间线背景，不可作为回复对象"
            }
            if let message = messages[event.id] {
                fields["addressedTo"] = message.mentionedUsers.map {
                    $0 == "all" ? "全体成员" : $0 == account ? "BOT（本账号）" : QQMemoryBook.subject(account: account, target: message.key, sender: $0)
                }.joined(separator: ",")
                if let reference = message.replyTo {
                    fields["replyTo"] = reference
                    fields["quotedSpeaker"] = self.speaker(for: reference) ?? "引用作者未核验，不猜测"
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { continue }
            let line = String(decoding: data, as: UTF8.self)
            guard used + line.count + 1 <= characters else { break }
            lines.append(line); used += line.count + 1
        }
        return lines.reversed().joined(separator: "\n")
    }

    public func speaker(for id: String) -> String? { events.first { $0.id == id }?.subject }

    public static let participationPrompt = participationPrompt(willingness: 5)
    /// Lower willingness makes “没必要接话” easier to accept. 5 is the current eager behavior.
    public static func participationPrompt(willingness: Int) -> String {
        let level = min(5, max(1, willingness))
        let stance: String
        switch level {
        case 1: stance = "接话意愿 1（最低）。很容易觉得没必要接话。闲聊、附和、已经有人在说、可接可不接，都设 participate=false，text 为空。只有别人明确抛出你可以接的新话题或问句时才 participate=true。"
        case 2: stance = "接话意愿 2。偏安静。没有清楚的新话题，或自己觉得没必要、不值得插话，就设 participate=false。"
        case 3: stance = "接话意愿 3。看情况。能自然接上当前话题就 participate=true；可接可不接时设 participate=false。"
        case 4: stance = "接话意愿 4。比较愿意接。只有完全没话可说、别人的私话，或旧话题已经回应过，才设 participate=false。"
        default: stance = "接话意愿 5（最高）。「没必要回、不值得插话、保持安静」的判断权重已调低，只要能接上当前话题就自然回复（participate=true），不要因为自己觉得没必要开口就把这一轮变成沉默。"
        }
        return """
    [QQ_PARTICIPATION] 本轮是主动加入群话题。程序已通过来源过滤、按人规则、白名单和额度核验；\(stance)
    紧邻图片或媒体若未能读取画面，请按文字时间线接话，需要提及时写明没看到画面，绝不能编造画面内容，也不要因为旁边有一张没读到的图就整轮保持安静。
    仅在以下无话可接的硬边界设 participate=false：当前时间线完全没有可理解的文字话题（例如只有未读取的媒体/卡片且无文字上下文）；纯属成员点名私密对话或主人明确只对其他成员交代事项，外人无法插话；旧话题已被 BOT 回应且其后没有新内容。主动发言默认面向全群，看清 speaker、addressedTo 与 quotedSpeaker，不把触发者、话题主角和回复对象混成同一个你，也不对标记为 filtered 的忽略名单发言回复。一句短梗比事实说教合适时就接梗，但不编造人物行为。
    输出格式覆盖前面的三项要求，必须包含布尔 participate，及 text、emotion、intensity；participate=false 时 text=""、emotion="neutral"、intensity=0，程序不会发送任何内容或表情。participate=true 时遵守原字数和短答规则。校对阶段只要能接上当前话题就修正草稿并保持 participate=true；若另有 sticker_id 要求则保留该字段。只输出 JSON，不解释是否参与。
    """
    }

    private static func readableText(_ text: String) -> String {
        // These are transport placeholders, not things a member actually said.
        var result = text
        for marker in ["（对方发来图片或表情包，请结合画面和前文简短回应。）", "（群成员发送了媒体或卡片，内容未读取，不要猜测）", "（群成员发来提及或引用，暂无文字内容）"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        result = result.replacingOccurrences(of: "（QQ 内置表情 ID [0-9]+，含义不确定时不要猜）", with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let prompt = "群聊接话规则：时间线只到本轮触发消息，按时间和发言人理解。先确定最新话题、谁在对谁说、代词指什么，再接话。最新明确的话题切换和纠正优先；真实引用可指向旧话题，但不要把没有引用的旧话题硬接过来。BOT 行是你已经说过的话，用于避免重复，不能当作群成员的事实或要求。长期记忆仅在当前话题确实相关时辅助，不可用它填补未读取的图片或过时话题。多个成员交错时，以本轮明确称呼/引用为先，其次紧邻的相关发言，不继承当前成员之前另一话题的对话。成员互相安排出行、借书、付款等生活事项时，你是旁观接话的 AI，不是参与安排的成员；不要代替成员答应，也不能声称自己已准备证件、付钱、到场或拥有实物。即使 BOT 旧回复说过这种话，也不能据此继续捏造；改为对他们的安排作相关短评。OWNER 仅代表本账号主人的人工发言，BOT 才是你，其他 MEMBER 标签是不同群成员。addressedTo 表示真实提及对象；没有提及不等于在对你说，尤其主人对其他成员的邀请和玩笑不可抢答。quotedSpeaker 属于被引用的那个人，不是当前发言者；引用 BOT 才是引用你，引用 OWNER 不要自认自己说过。群聊里的“你”先对准提及/引用对象，不能默认是 BOT。图片或媒体未读到时写明没看到画面，按文字时间线接话；不编故事，也不重复已经说过的评论。"
}
