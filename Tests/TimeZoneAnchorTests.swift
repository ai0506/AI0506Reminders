import Foundation
import Testing
@testable import AI0506_Reminders

/// 相对日期必须锚在 Asia/Shanghai，而不是设备时区。
///
/// 这些用例**真的把进程默认时区改掉**再跑解析——只断言「结果等于上海算出来的那个时刻」
/// 是不够的：开发机本来就在上海，那样的断言把 `Calendar.current` 换回来也照样绿。
/// 所以这里改全局状态，用 `.serialized` 保证套内不并发，每个用例结束一定还原。
/// 其它测试已经不读环境时区了（`MockAIDeadlineParserTests` 和 `SharedFixtureTests`
/// 都显式用上海日历），所以这个翻转不会波及并行跑的别的套件。
@Suite(.serialized)
struct TimeZoneAnchorTests {
    private let shanghai = Calendar.shanghai

    /// 挑的这个时刻横跨自然日：上海 8/17 00:30 在洛杉矶还是 8/16 上午。
    /// 按设备时区算，「明天」会落到 8/17；按上海算才是 8/18。
    private var lateNightInShanghai: Date {
        shanghai.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 0, minute: 30))!
    }

    private func inTimeZone<T>(_ identifier: String, _ body: () throws -> T) rethrows -> T {
        let original = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: identifier)!
        defer { NSTimeZone.default = original }
        return try body()
    }

    @Test(arguments: ["America/Los_Angeles", "Europe/London", "Asia/Shanghai"])
    func tomorrowIsTheNextShanghaiDayWhereverTheDeviceIs(zone: String) throws {
        let now = lateNightInShanghai
        let timing = inTimeZone(zone) {
            MockAIDeadlineParser.timing(in: "明天把物理卷子写完", now: now)
        }

        #expect(timing.isAllDay)
        let parts = shanghai.dateComponents([.year, .month, .day, .hour], from: timing.date)
        #expect(parts.month == 8)
        #expect(parts.day == 18)
        #expect(parts.hour == 0)
    }

    @Test(arguments: ["America/Los_Angeles", "Europe/London", "Asia/Shanghai"])
    func explicitClockTimeLandsOnTheShanghaiWallClock(zone: String) throws {
        let now = lateNightInShanghai
        let timing = inTimeZone(zone) {
            MockAIDeadlineParser.timing(in: "明天下午三点交作业", now: now)
        }

        #expect(!timing.isAllDay)
        let parts = shanghai.dateComponents([.month, .day, .hour, .minute], from: timing.date)
        #expect(parts.month == 8)
        #expect(parts.day == 18)
        #expect(parts.hour == 15)
        #expect(parts.minute == 0)
    }

    /// 星期偏移是按「今天是周几」算的，所以跨日的那半小时里最容易错一整天。
    /// 上海 8/17 是周一，「周五」应当落在 8/21；按洛杉矶算今天还是周日，会落到 8/20。
    @Test(arguments: ["America/Los_Angeles", "Europe/London", "Asia/Shanghai"])
    func weekdayOffsetCountsFromTheShanghaiToday(zone: String) throws {
        let now = lateNightInShanghai
        let timing = inTimeZone(zone) {
            MockAIDeadlineParser.timing(in: "周五下午三点交实验报告", now: now)
        }

        let parts = shanghai.dateComponents([.month, .day, .hour], from: timing.date)
        #expect(parts.month == 8)
        #expect(parts.day == 21)
        #expect(parts.hour == 15)
    }

    /// 没写时间也没写日期时走的是「两天后」的兜底，同样不能跟着设备时区漂。
    @Test(arguments: ["America/Los_Angeles", "Asia/Shanghai"])
    func theNoDateFallbackAlsoUsesShanghai(zone: String) throws {
        let now = lateNightInShanghai
        let timing = inTimeZone(zone) {
            MockAIDeadlineParser.timing(in: "把选题意向表发出去", now: now)
        }

        #expect(timing.isAllDay)
        #expect(!timing.wasExplicit)
        let parts = shanghai.dateComponents([.month, .day, .hour], from: timing.date)
        #expect(parts.month == 8)
        #expect(parts.day == 19)
        #expect(parts.hour == 0)
    }
}
