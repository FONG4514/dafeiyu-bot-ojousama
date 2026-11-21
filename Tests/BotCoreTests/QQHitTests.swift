import Foundation
import Testing
@testable import BotCore

struct QQHitTests {
    @Test func commandAcceptsOnlyTheHitPhrase() {
        #expect(QQHitClock.matches("/hit"))
        #expect(QQHitClock.matches("/HIT 打一下"))
        #expect(!QQHitClock.matches("/hitter"))
        #expect(!QQHitClock.matches("/hit 别的"))
        #expect(QQHitClock.faintReply == "[晕倒惹，晕乎乎]")
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
    }
}
