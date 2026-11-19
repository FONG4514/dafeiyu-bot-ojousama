import Foundation
import Testing
@testable import BotCore

struct QQLocalClockTests {
    @Test func clockQuestionsAreRecognizedWithoutTreatingPlansAsQuestions() {
        #expect(QQLocalClock.asks("现在几点了"))
        #expect(QQLocalClock.asks("今天几号"))
        #expect(QQLocalClock.asks("What time is it"))
        #expect(!QQLocalClock.asks("我们几点见面"))
        #expect(!QQLocalClock.asks("明天去爬山"))
    }
    @Test func promptUsesTheGivenZoneAndOmitsPlaceNames() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 17, minute: 5, second: 6))!
        let prompt = QQLocalClock.prompt(now: now, calendar: calendar)
        #expect(prompt.contains("2026-11-19 17:05:06"))
        #expect(prompt.contains("时区偏移 +08:00"))
        #expect(!prompt.contains("Shanghai"))
        #expect(!prompt.contains("市区"))
    }
}
