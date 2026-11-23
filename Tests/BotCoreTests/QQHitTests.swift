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
        #expect(!fourth.contains("晕倒惹，晕乎乎"))
        let bully = QQHitClock.bullyInstruction(count: 2, name: "合成甲")
        #expect(bully.contains("欺负 合成甲 的第 2 下"))
        #expect(bully.contains("触发这条命令的人的当前生效性格"))
        #expect(!bully.contains("态度："))
        #expect(!bully.contains("[打晕惹]"))
    }

    @Test func bullyTargetRequiresTheMarkedUser() throws {
        var config = QQConfig()
        var marked = QQSenderPersona(number: "54321", style: .gentle)
        marked.names = ["合成甲"]; marked.bully = true
        var plain = QQSenderPersona(number: "54322", style: .calm)
        plain.names = ["合成乙"]
        config.senderPersonas = [marked, plain]
        let atMarked = QQIncoming(id: "1", sender: "77777", target: "99999", group: true, text: "/欺负", time: 1, replyTo: nil, images: [], mentionedUsers: ["54321"])
        #expect(config.bullyTarget(atMarked, phrase: "")?.number == "54321")
        #expect(config.hitVictim(in: atMarked)?.number == "54321")
        #expect(config.persona(for: atMarked).effectiveStyle == .teasing)
        let byName = QQIncoming(id: "2", sender: "54322", target: "99999", group: true, text: "/欺负 合成甲", time: 1, replyTo: nil, images: [])
        #expect(config.bullyTarget(byName, phrase: "合成甲")?.number == "54321")
        #expect(config.hitVictim(in: byName)?.number == "54321")
        #expect(config.persona(for: byName).effectiveStyle == .calm)
        let unmarked = QQIncoming(id: "3", sender: "77777", target: "99999", group: true, text: "/欺负", time: 1, replyTo: nil, images: [], mentionedUsers: ["54322"])
        #expect(config.bullyTarget(unmarked, phrase: "") == nil)
        #expect(config.hitVictim(in: unmarked) == nil)
        let bot = QQIncoming(id: "4", sender: "77777", target: "99999", group: true, text: "/欺负", time: 1, replyTo: nil, images: [])
        #expect(config.bullyTarget(bot, phrase: "") == nil)
        #expect(config.hitVictim(in: bot) == nil)
        #expect(config.bullyTarget(bot, phrase: "打一下") == nil)
        let old = QQIncoming(id: "7", sender: "54321", target: "54321", group: false, text: "/hit", time: 1, replyTo: nil, images: [])
        #expect(config.hitVictim(in: old) == nil)
        config.expectedSelfID = "12345"
        let privateMarked = QQIncoming(id: "5", sender: "54321", target: "54321", group: false, text: "/欺负", time: 1, replyTo: nil, images: [])
        #expect(config.hitVictim(in: privateMarked)?.number == "54321")
        #expect(config.persona(for: privateMarked).effectiveStyle == .gentle)
        let privatePlain = QQIncoming(id: "6", sender: "54322", target: "54322", group: false, text: "/欺负", time: 1, replyTo: nil, images: [])
        #expect(config.hitVictim(in: privatePlain) == nil)
        #expect(config.hitNamesSomeone(privatePlain))
        #expect(config.hitNamesSomeone(unmarked))
        #expect(!config.hitNamesSomeone(bot))
        let stored = try JSONDecoder().decode(QQSenderPersona.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","number":"54321","style":"gentle"}"#.utf8))
        #expect(!stored.bullies)
    }
}
