import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import BotCore
@testable import WeChatAIBot

private final class PersonalityModelProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var prompts: [String] = []
    static func reset() { lock.lock(); prompts = []; lock.unlock() }
    static var captured: [String] { lock.lock(); defer { lock.unlock() }; return prompts }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) }
        }
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let messages = object["messages"] as! [[String: Any]], prompt = messages[0]["content"] as! String
        Self.lock.lock(); Self.prompts.append(prompt); Self.lock.unlock()
        let style = QQPersonality.allCases.first { prompt.contains("当前会话唯一生效性格：" + $0.name) }
        #expect(style != nil)
        var answer: [String: Any] = ["text": "合成回复：" + (style?.name ?? "未识别"), "emotion": "neutral", "intensity": 0]
        if prompt.contains("[QQ_PARTICIPATION]") { answer["participate"] = true }
        let content = String(decoding: try! JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
        let result: [String: Any] = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result)); client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) @MainActor struct QQPersonalityEngineTests {
    @Test func panelPersistenceKeepsMemoryAndRollsBackStaleWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seed = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        seed.config.expectedSelfID = "12345"
        seed.config.targets = [QQTarget(number: "54321", name: "peer", group: false), QQTarget(number: "99999", name: "group", group: true)]
        seed.save()
        let file = directory.appendingPathComponent("qq-state.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var book = QQMemoryBook()
        book.append(QQMemoryEvent(id: "1", subject: "PEER", text: "synthetic preference blue", at: Date()))
        raw["memoryBooks"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(["12345:private:54321": book]))
        try JSONSerialization.data(withJSONObject: raw).write(to: file)
        let engine = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        engine.setPersonaStyle("gentle", target: "private:54321")
        #expect(engine.error == nil); #expect(engine.memoryBooks["12345:private:54321"] == book)
        let restored = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        #expect(restored.config.persona(for: "private:54321").effectiveStyle == .gentle)
        #expect(restored.memoryBooks["12345:private:54321"] == book)
        engine.setPersonaStyle("invalid", target: "group:99999")
        #expect(engine.error != nil); #expect(engine.config.persona(for: "group:99999").effectiveStyle == .teasing)
        engine.setPersonaStyle("calm", target: "group:77777")
        #expect(engine.error != nil); #expect(engine.config.targets.count == 2)
        // A second legitimate panel changes the file; this stale panel must not override it.
        restored.setPersonaStyle("butler", target: "group:99999")
        engine.setPersonaStyle("calm", target: "private:54321")
        #expect(engine.error != nil); #expect(engine.config.persona(for: "private:54321").effectiveStyle == .gentle)
        let latest = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        #expect(latest.config.persona(for: "group:99999").effectiveStyle == .butler)
        #expect(latest.memoryBooks["12345:private:54321"] == book)
    }
    @Test func removingOrRenumberingBindingClearsOnlyItsSharedMemory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bound = QQSenderPersona(number: "54321", style: .gentle)
        let seed = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        seed.config.expectedSelfID = "12345"; seed.config.senderPersonas = [bound]
        seed.save()
        let file = directory.appendingPathComponent("qq-state.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var book = QQMemoryBook()
        book.append(QQMemoryEvent(id: "1", subject: "PEER", text: "synthetic preference blue", at: Date()))
        let shared = "12345:persona:" + bound.id.uuidString
        raw["memoryBooks"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([shared: book, "12345:private:77777": book]))
        try JSONSerialization.data(withJSONObject: raw).write(to: file)
        let engine = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        engine.saveReplySettings(ai: engine.config.ai, persona: engine.config.effectivePersona, senderPersonas: [bound])
        #expect(engine.error == nil); #expect(engine.memoryBooks[shared] == book)
        var renumbered = bound; renumbered.number = "66666"
        engine.saveReplySettings(ai: engine.config.ai, persona: engine.config.effectivePersona, senderPersonas: [renumbered])
        #expect(engine.error == nil); #expect(engine.memoryBooks[shared] == nil)
        #expect(engine.memoryBooks["12345:private:77777"] == book)
        let restored = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        #expect(restored.config.effectiveSenderPersonas == [renumbered])
        #expect(restored.memoryBooks[shared] == nil); #expect(restored.memoryBooks["12345:private:77777"] == book)
    }
    @Test(arguments: ["group", "private", "owner"])
    func personaCommandsAreDisabled(_ mode: String) async throws {
        try await withFixture(configure: { $0.config.effectiveMemoryEnabled = true }) { engine, directory in
            var command = Self.event(1, "/persona gentle", group: mode == "private" ? nil : "99999", mention: mode == "group")
            if mode == "owner" { command["post_type"] = "message_sent"; command["user_id"] = 12345; command["sender"] = ["user_id": 12345] }
            try writePrivateData(JSONSerialization.data(withJSONObject: [command]), to: directory.appendingPathComponent("event-batch"))
            try await Self.wait(seconds: 5) { engine.logs.contains { $0.detail.contains("性格命令已停用") } }
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(engine.logs.contains { $0.detail.contains("性格命令已停用") })
            #expect(engine.sends.attempts == 0); #expect(engine.usage.calls == 0)
            #expect(PersonalityModelProtocol.captured.isEmpty); #expect(engine.memoryBooks.isEmpty)
            #expect(engine.config.persona(for: mode == "private" ? "private:54321" : "group:99999").effectiveStyle == .teasing)
        }
    }
    @Test(arguments: QQPersonality.allCases.map(\.rawValue) + ["proactive", "memory"])
    func senderPersonaRoutesRepliesAndMemory(_ mode: String) async throws {
        let style = QQPersonality(rawValue: mode) ?? .gentle
        var bound = QQSenderPersona(number: "54321", style: style)
        bound.names = ["合成甲"]
        if style == .custom { bound.customName = "合成角色"; bound.customPrompt = "SYNTHETIC_BOUND_STYLE：自然简短的游戏搭子。" }
        try await withFixture(configure: { engine in
            engine.config.senderPersonas = [bound]
            engine.config.effectiveMemoryEnabled = mode == "memory"
            engine.config.effectiveGroupParticipationEvery = mode == "proactive" ? 1 : 10
        }) { engine, directory in
            // The bound user speaks in one group; an unbound member speaks in another.
            let batch = [Self.event(2, "今天聊天测试", mention: mode != "proactive"), Self.event(3, "另一个群测试，合成甲在吗", sender: 66666, group: "88888", mention: true)]
            try writePrivateData(JSONSerialization.data(withJSONObject: batch), to: directory.appendingPathComponent("event-batch"))
            try await Self.wait(seconds: 9) { engine.sends.confirmed >= 2 || engine.sends.uncertain > 0 }
            #expect(engine.sends.confirmed == 2); #expect(engine.sends.uncertain == 0)
            let prompts = PersonalityModelProtocol.captured
            #expect(prompts.count == 4)
            #expect(prompts.prefix(2).allSatisfy { $0.contains("当前会话唯一生效性格：" + style.name) })
            #expect(prompts.suffix(2).allSatisfy { $0.contains("当前会话唯一生效性格：" + QQPersonality.teasing.name) })
            if style == .custom {
                #expect(prompts.prefix(2).allSatisfy { $0.contains("SYNTHETIC_BOUND_STYLE") })
                #expect(prompts.suffix(2).allSatisfy { !$0.contains("SYNTHETIC_BOUND_STYLE") })
            }
            #expect(prompts.suffix(2).allSatisfy { $0.contains("你认识的熟人") && $0.contains("常用称呼：合成甲") && $0.contains("[MEMBER_") })
            #expect(prompts.prefix(2).allSatisfy { !$0.contains("你认识的熟人") })
            #expect(prompts.prefix(2).allSatisfy { $0.contains("[关系卡片]") && $0.contains("（就是当前发言者）") })
            #expect(prompts.suffix(2).allSatisfy { $0.contains("[关系卡片]") && $0.contains("（本轮被提到）") && $0.contains("不整段换成被提到者的人设") })
            if mode == "proactive" { #expect(prompts.first?.contains("[QQ_PARTICIPATION]") == true) }
            if mode == "memory" {
                #expect(prompts.prefix(2).allSatisfy { $0.contains("本轮记忆只属于群 99999") && $0.contains("chat=\"99999\"") && $0.contains("recall_memory") })
                #expect(prompts.suffix(2).allSatisfy { $0.contains("chat=\"88888\"") && !$0.contains("chat=\"99999\"") })
                let group = try #require(engine.memoryBooks["12345:group:99999"])
                #expect(group.recent.contains { $0.id == "2" && $0.subject.hasPrefix("MEMBER_") })
                #expect(engine.memoryBooks["12345:persona:" + bound.id.uuidString] == nil)
                #expect(engine.memoryBooks["12345:private:54321"] == nil)
                let other = try #require(engine.memoryBooks["12345:group:88888"])
                #expect(other.recent.contains { $0.id == "3" && $0.subject.hasPrefix("MEMBER_") })
                #expect(!other.recent.contains { $0.id == "2" })
                #expect(!other.recent.contains { $0.text.contains("（此句提到 PEER）") })
                #expect(prompts.allSatisfy { $0.contains("私聊与群聊互不读取") })
            } else {
                #expect(prompts.allSatisfy { !$0.contains("recall_memory") && !$0.contains("本轮记忆只属于") })
            }
        }
    }
    private static func event(_ id: Int, _ text: String, sender: Int = 54321, group: String? = "99999", mention: Bool = false) -> [String: Any] {
        var parts: [[String: Any]] = [["type": "text", "data": ["text": text]]]
        if mention { parts.insert(["type": "at", "data": ["qq": "12345"]], at: 0) }
        var row: [String: Any] = ["post_type": "message", "self_id": 12345, "user_id": sender, "sender": ["user_id": sender], "message_id": id, "message_type": group == nil ? "private" : "group", "sub_type": group == nil ? "friend" : "normal", "message": parts]
        if let group { row["group_id"] = Int(group)! }
        return row
    }
    private static func wait(seconds: Double, until done: () -> Bool) async throws {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until, !done() { try await Task.sleep(nanoseconds: 20_000_000) }
    }
    private func withFixture(configure: (QQEngine) -> Void, _ body: (QQEngine, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("groupParticipation".utf8).write(to: directory.appendingPathComponent("message-shape"))
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DAFEIYU_PYTHON"] ?? "/usr/bin/python3")
        server.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("onebot_fixture.py").path, directory.path]
        server.standardOutput = output; try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let port = try #require(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        PersonalityModelProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [PersonalityModelProtocol.self]
        let session = URLSession(configuration: cfg); defer { session.invalidateAndCancel() }
        let engine = QQEngine(allowAuthenticationUI: false, storageDirectory: directory, modelClient: DeepSeekClient(session: session))
        defer { engine.disconnect() }
        engine.config.endpoint = "ws://127.0.0.1:\(port)"; engine.config.expectedSelfID = "12345"
        engine.config.effectivePersona.stickersEnabled = false; engine.config.effectiveArtwork.enabled = false
        engine.config.effectiveImageGeneration.enabled = false; engine.config.effectiveOnlineEnabled = false
        engine.config.ai.cooldownSeconds = 1; engine.config.ai.effectiveSendLimits.globalIntervalSeconds = 1
        engine.config.effectiveGroupParticipationEnabled = true
        configure(engine)
        #expect(engine.useTemporaryCredentials(token: "synthetic-test-token", key: "synthetic-key"))
        await engine.connect(); try #require(engine.connected, "\(engine.error ?? engine.status)")
        for contact in engine.contacts { engine.add(contact) }
        for index in engine.config.targets.indices { engine.config.targets[index].enabled = true }
        engine.start(); try #require(engine.running, "\(engine.error ?? engine.status)")
        try await body(engine, directory)
    }
}
