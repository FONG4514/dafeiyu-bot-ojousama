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
}
