import Foundation
import Testing
@testable import BotCore

struct QQHitTests {
    @Test func commandAcceptsOnlyTheHitPhrase() {
        #expect(QQHitClock.matches("/hit"))
        #expect(QQHitClock.matches("/HIT 打一下"))
        #expect(!QQHitClock.matches("/hitter"))
        #expect(!QQHitClock.matches("/hit 别的"))
        #expect(QQHitClock.rest("/hit 合成甲") == "合成甲")
        #expect(QQHitClock.rest("/hitter") == nil)
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
        #expect(bully.contains("打 合成甲 的第 2 下"))
        #expect(bully.contains("不是自己挨打"))
        #expect(!bully.contains("[打晕惹]"))
    }

    @Test func bullyTargetRequiresTheMarkedUser() throws {
        var config = QQConfig()
        var marked = QQSenderPersona(number: "54321", style: .gentle)
        marked.names = ["合成甲"]; marked.bully = true
        var plain = QQSenderPersona(number: "54322", style: .calm)
        plain.names = ["合成乙"]
        config.senderPersonas = [marked, plain]
        let atMarked = QQIncoming(id: "1", sender: "77777", target: "99999", group: true, text: "/hit", time: 1, replyTo: nil, images: [], mentionedUsers: ["54321"])
        #expect(config.bullyTarget(atMarked, phrase: "")?.number == "54321")
        let byName = QQIncoming(id: "2", sender: "77777", target: "99999", group: true, text: "/hit 合成甲", time: 1, replyTo: nil, images: [])
        #expect(config.bullyTarget(byName, phrase: "合成甲")?.number == "54321")
        let unmarked = QQIncoming(id: "3", sender: "77777", target: "99999", group: true, text: "/hit", time: 1, replyTo: nil, images: [], mentionedUsers: ["54322"])
        #expect(config.bullyTarget(unmarked, phrase: "") == nil)
        let bot = QQIncoming(id: "4", sender: "77777", target: "99999", group: true, text: "/hit", time: 1, replyTo: nil, images: [])
        #expect(config.bullyTarget(bot, phrase: "") == nil)
        #expect(config.bullyTarget(bot, phrase: "打一下") == nil)
        let stored = try JSONDecoder().decode(QQSenderPersona.self, from: Data(#"{"number":"54321","style":"gentle"}"#.utf8))
        #expect(!stored.bullies)
    }
}
