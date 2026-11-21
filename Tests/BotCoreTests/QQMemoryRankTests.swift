import Foundation
import Testing
@testable import BotCore

struct QQMemoryRankTests {
    @Test func scorePrefersRecentFrequentRequestedMemories() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = QQMemoryRank.score(lexical: 1, last: now, mentions: 1, importance: 2, requestedCategory: true, now: now)
        #expect(abs(fresh - 2.5) < 0.001)
        let old = QQMemoryRank.score(lexical: 1, last: now.addingTimeInterval(-70 * 86400), mentions: 1, importance: 2, requestedCategory: false, now: now)
        #expect(old < fresh)
        #expect(QQMemoryRank.frequency(10_000) == 1)
        #expect(QQMemoryIndex.terms("喜欢晚饭").contains("喜欢"))
    }
    @Test func categoryNamesAreNormalizedAndCapped() {
        #expect(QQMemoryCategory.checked(["喜欢的食物", "偏好"]) == ["喜欢的食物", "偏好"])
        #expect(QQMemoryCategory.checked(["甲"]) == nil)
        #expect(QQMemoryCategory.checked(["12345678"]) == nil)
        #expect(QQMemoryCategory.checked(["食物", "食物"]) == nil)
        let existing = (0..<64).map { "类别\($0)" }
        #expect(QQMemoryCategory.fit(["喜欢的食物"], existing: existing) == ["其他"])
        #expect(QQMemoryMode.superMemory.trigger(base: QQMemoryOptions(), superLimited: false).messages == 8)
        #expect(QQMemoryMode.fast.trigger(base: QQMemoryOptions(), superLimited: false).minutes == 240)
        #expect(QQMemoryMode.balanced.trigger(base: QQMemoryOptions(), superLimited: false).messages == 20)
        #expect(QQMemoryRecall.parse(#"{"chat":"99999","categories":["偏好"],"query":"晚饭"}"#, expectedChat: "99999")?.query == "晚饭")
        #expect(QQMemoryRecall.parse(#"{"chat":"54321"}"#, expectedChat: "99999") == nil)
        #expect(QQMemoryRecall.resolved(arguments: #"{"chat":"54321","query":"晚饭\n换行"}"#, expectedChat: "99999", fallbackQuery: "当前话题吃面").query == "当前话题吃面")
        #expect(QQMemoryRecall.resolved(arguments: #"{"chat":"99999","query":"晚饭"}"#, expectedChat: "99999", fallbackQuery: "别的").query == "晚饭")
    }
}
