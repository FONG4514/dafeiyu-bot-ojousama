import Foundation
import Testing
@testable import WeChatAIBot
import BotCore

struct QQMemoryStoreTests {
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    @Test func recallStaysInsideOneScopeAndSurvivesSnapshot() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try QQMemoryStore(directory: directory, limitMB: 256)
        let privateItem = QQMemoryItem(subject: "PEER", kind: "preference", text: "私聊喜欢清淡晚饭", keywords: ["晚饭"], importance: 2, sourceIDs: ["1"], updatedAt: now, expiresAt: now.addingTimeInterval(86400))
        let groupItem = QQMemoryItem(subject: "MEMBER_abc", kind: "fact", text: "群里只谈过天气", keywords: ["天气"], importance: 1, sourceIDs: ["2"], updatedAt: now, expiresAt: now.addingTimeInterval(86400))
        try store.importScope("12345:private:54321", items: [privateItem])
        try store.importScope("12345:group:99999", items: [groupItem])
        let group = store.recall(scope: "12345:group:99999", query: "晚饭", categories: [], history: false, subject: "MEMBER_abc", now: now).0
        #expect(!group.contains("清淡"))
        let recalled = store.recall(scope: "12345:private:54321", query: "晚饭", categories: [], history: false, subject: "PEER", now: now).0
        #expect(recalled.contains("清淡晚饭") && recalled.contains("2027"))
        try store.addEvent(scope: "12345:private:54321", event: QQMemoryEvent(id: "9", subject: "PEER", text: "私聊原话提到晚饭", at: now))
        #expect(store.recall(scope: "12345:private:54321", query: "原话", categories: [], history: false, subject: "PEER", now: now).0.contains("私聊原话"))
        try store.snapshot()
        let restored = try QQMemoryStore(directory: directory, limitMB: 256)
        #expect(restored.contains("12345:private:54321", text: "私聊喜欢清淡晚饭"))
        #expect(restored.factCount("12345:group:99999") == 1)
        try restored.deleteScope("12345:private:54321")
        #expect(restored.factCount("12345:private:54321") == 0)
        #expect(restored.factCount("12345:group:99999") == 1)
        try store.testingRollback()
    }
    @Test func unsavedMemoryDoesNotReappear() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = try QQMemoryStore(directory: directory, limitMB: 256)
        let now = Date()
        try first.importScope("12345:private:54321", items: [QQMemoryItem(subject: "PEER", kind: "fact", text: "尚未落盘", keywords: [], importance: 1, sourceIDs: [], updatedAt: now, expiresAt: now.addingTimeInterval(86400))])
        let second = try QQMemoryStore(directory: directory, limitMB: 256)
        #expect(second.factCount("12345:private:54321") == 0)
    }
    @Test func privateChatReadsPeerGroupMemoriesWhileGroupNeverReadsPrivate() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try QQMemoryStore(directory: directory, limitMB: 256)
        let peerInGroup = QQMemoryBook.subject(account: "12345", target: "group:99999", sender: "54321")
        let otherInGroup = QQMemoryBook.subject(account: "12345", target: "group:99999", sender: "66666")
        let privateSecret = QQMemoryItem(subject: "PEER", kind: "preference", text: "私聊秘密偏好抹茶蛋糕", keywords: ["抹茶", "蛋糕"], importance: 3, sourceIDs: ["p1"], updatedAt: now, expiresAt: now.addingTimeInterval(86400))
        let peerGroupFact = QQMemoryItem(subject: peerInGroup, kind: "task", text: "群里约定周六去天文馆", keywords: ["天文馆", "周六"], importance: 2, sourceIDs: ["g1"], updatedAt: now, expiresAt: now.addingTimeInterval(86400))
        let otherGroupFact = QQMemoryItem(subject: otherInGroup, kind: "fact", text: "另一群成员周日去钓鱼", keywords: ["钓鱼", "周日"], importance: 2, sourceIDs: ["g2"], updatedAt: now, expiresAt: now.addingTimeInterval(86400))
        try store.importScope("12345:private:54321", items: [privateSecret])
        try store.importScope("12345:group:99999", items: [peerGroupFact, otherGroupFact])
        try store.addEvent(scope: "12345:group:99999", event: QQMemoryEvent(id: "ge1", subject: peerInGroup, text: "群内原话：我买了望远镜", at: now))
        try store.addEvent(scope: "12345:group:99999", event: QQMemoryEvent(id: "ge2", subject: otherInGroup, text: "别人群内原话：我买了鱼竿", at: now))

        // Private chat with 54321 can read 54321's group memories and events, but not 66666's.
        let privatePrompt = store.prompt(scope: "12345:private:54321", query: "天文馆", subject: "PEER", characters: 600, now: now)
        #expect(privatePrompt.contains("天文馆") && privatePrompt.contains("PEER(群记忆)"))
        #expect(!privatePrompt.contains("钓鱼"))
        let privateRecall = store.recall(scope: "12345:private:54321", query: "望远镜", categories: [], history: false, subject: "PEER", now: now).0
        #expect(privateRecall.contains("望远镜") && !privateRecall.contains("鱼竿"))
        let privateOtherQuery = store.recall(scope: "12345:private:54321", query: "钓鱼 鱼竿", categories: [], history: false, subject: "PEER", now: now).0
        #expect(!privateOtherQuery.contains("钓鱼") && !privateOtherQuery.contains("鱼竿"))

        // Group 99999 can never read 54321's private memories.
        let groupPrompt = store.prompt(scope: "12345:group:99999", query: "抹茶蛋糕", subject: peerInGroup, characters: 600, now: now)
        #expect(!groupPrompt.contains("抹茶"))
        let groupRecall = store.recall(scope: "12345:group:99999", query: "抹茶蛋糕", categories: [], history: false, subject: peerInGroup, now: now).0
        #expect(!groupRecall.contains("抹茶"))
    }
}
