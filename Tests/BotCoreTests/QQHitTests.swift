import Foundation
import Testing
@testable import BotCore

struct QQHitTests {
    @Test func commandAcceptsOnlyTheHitPhrase() {
        #expect(QQHitClock.matches("/欺负"))
        #expect(QQHitClock.matches("/欺负 打一下"))
        #expect(!QQHitClock.matches("/hit"))
        #expect(!QQHitClock.matches("/欺负者"))
        #expect(!QQHitClock.matches("/欺负 别的"))
        #expect(QQHitClock.rest("/欺负 合成甲") == "合成甲")
        #expect(QQHitClock.rest("/hit") == nil)
        #expect(QQHitClock.rest("/欺负者") == nil)
        #expect(QQHitClock.faintReply == "[晕倒惹，晕乎乎]")
        #expect(QQHitClock.bullyFaintReply == "[打晕惹]")
    }

    @Test func fiveHitsInsideThreeMinutesFaintForOneMinute() {
        var clock = QQHitClock()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 1...4 {
            #expect(clock.hit(at: start.addingTimeInterval(Double(index))) == .dizzy(index))
            #expect(!clock.isFainted(at: start.addingTimeInterval(Double(index))))
        }
        #expect(clock.hit(at: start.addingTimeInterval(10)) == .faint)
        #expect(clock.isFainted(at: start.addingTimeInterval(69)))
        #expect(!clock.isFainted(at: start.addingTimeInterval(70)))
        #expect(clock.hit(at: start.addingTimeInterval(70)) == .dizzy(1))
    }

    @Test func aHitOutsideTheWindowDoesNotCarryTheOldCount() {
        var clock = QQHitClock()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<4 { _ = clock.hit(at: start) }
        #expect(clock.hit(at: start.addingTimeInterval(180)) == .dizzy(1))
    }

    @Test func modelOnlyReceivesTheCountedHit() {
        let first = QQHitClock.modelInstruction(count: 1)
        let fourth = QQHitClock.modelInstruction(count: 4)
        #expect(first.contains("第 1 下"))
        #expect(fourth.contains("第 4 下"))
        #expect(first.contains("程序已经点清"))
        #expect(first.contains("发令的人在欺负你"))
        #expect(first.contains("对这个发令的人该用的回话性格"))
        #expect(!fourth.contains("晕倒惹，晕乎乎"))
    }

    @Test func bullyTargetRequiresTheMarkedUser() throws {
        var config = QQConfig()
        var marked = QQSenderPersona(number: "54321", style: .gentle)
        marked.names = ["合成甲"]; marked.bully = true
        var plain = QQSenderPersona(number: "54322", style: .calm)
        plain.names = ["合成乙"]
        config.senderPersonas = [marked, plain]
        let fromMarked = QQIncoming(id: "1", sender: "54321", target: "99999", group: true, text: "/欺负", time: 1, replyTo: nil, images: [])
        #expect(config.bullySender(in: fromMarked)?.number == "54321")
        #expect(config.persona(for: fromMarked).effectiveStyle == .gentle)
        let namingSomeoneElse = QQIncoming(id: "2", sender: "54321", target: "99999", group: true, text: "/欺负 合成乙", time: 1, replyTo: nil, images: [])
        #expect(config.bullySender(in: namingSomeoneElse) == nil)
        let fromUnmarked = QQIncoming(id: "3", sender: "54322", target: "99999", group: true, text: "/欺负", time: 1, replyTo: nil, images: [])
        #expect(config.bullySender(in: fromUnmarked) == nil)
        #expect(config.persona(for: fromUnmarked).effectiveStyle == .calm)
        let stranger = QQIncoming(id: "4", sender: "77777", target: "99999", group: true, text: "/欺负", time: 1, replyTo: nil, images: [], mentionedUsers: ["54321"])
        #expect(config.bullySender(in: stranger) == nil)
        let old = QQIncoming(id: "7", sender: "54321", target: "54321", group: false, text: "/hit", time: 1, replyTo: nil, images: [])
        #expect(config.bullySender(in: old) == nil)
        let privateMarked = QQIncoming(id: "5", sender: "54321", target: "54321", group: false, text: "/欺负", time: 1, replyTo: nil, images: [])
        #expect(config.bullySender(in: privateMarked)?.number == "54321")
        #expect(config.persona(for: privateMarked).effectiveStyle == .gentle)
        let privatePlain = QQIncoming(id: "6", sender: "54322", target: "54322", group: false, text: "/欺负", time: 1, replyTo: nil, images: [])
        #expect(config.bullySender(in: privatePlain) == nil)
        let stored = try JSONDecoder().decode(QQSenderPersona.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","number":"54321","style":"gentle"}"#.utf8))
        #expect(!stored.bullies)
    }
}
