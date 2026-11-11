import Foundation
import XCTest
@testable import AgentScopeCore

final class ScheduleCalculatorTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func next(_ cron: String, after: String) -> Date? {
        ScheduleCalculator.nextRun(of: ScheduleCalculator.cronSchedule(cron)!, after: date(after), calendar: calendar)
    }

    func testCronStepAndRanges() {
        XCTAssertEqual(next("*/15 * * * *", after: "2026-11-11 09:07"), date("2026-11-11 09:15"))
        XCTAssertEqual(next("0 9-17 * * 1-5", after: "2026-11-13 17:30"), date("2026-11-16 09:00"))
        XCTAssertEqual(next("30 2 * * *", after: "2026-11-11 02:30"), date("2026-11-12 02:30"))
        XCTAssertEqual(next("5,35 * * * *", after: "2026-11-11 09:10"), date("2026-11-11 09:35"))
    }

    func testCronCrossesMonthAndWeekdaySevenIsSunday() {
        XCTAssertEqual(next("0 0 1 * *", after: "2026-11-30 12:00"), date("2026-12-01 00:00"))
        XCTAssertEqual(next("0 8 * * 7", after: "2026-11-11 09:00"), date("2026-11-15 08:00"))
        XCTAssertEqual(next("0 0 29 2 *", after: "2026-03-01 00:00"), date("2028-02-29 00:00"))
    }

    func testCronDayAndWeekdayAreEitherOr() {
        // 15th of the month OR any Monday
        XCTAssertEqual(next("0 0 15 * 1", after: "2026-11-11 00:00"), date("2026-11-15 00:00"))
        XCTAssertEqual(next("0 0 15 * 1", after: "2026-11-15 00:00"), date("2026-11-16 00:00"))
    }

    func testCronKeywordsAndInvalidInput() {
        XCTAssertEqual(next("@daily", after: "2026-11-11 09:00"), date("2026-11-12 00:00"))
        XCTAssertEqual(next("@hourly", after: "2026-11-11 09:00"), date("2026-11-11 10:00"))
        XCTAssertNil(ScheduleCalculator.cronSchedule("@reboot"))
        XCTAssertNil(ScheduleCalculator.cronSchedule("61 * * * *"))
        XCTAssertNil(ScheduleCalculator.cronSchedule("* * *"))
    }

    func testLaunchdCalendarIntervalDictionaryAndArray() {
        let single = ScheduleCalculator.launchdSchedules(["Hour": 3, "Minute": 15])
        XCTAssertEqual(
            ScheduleCalculator.nextRun(of: single, after: date("2026-11-11 09:00"), calendar: calendar),
            date("2026-11-12 03:15")
        )
        let many = ScheduleCalculator.launchdSchedules([
            ["Weekday": 0, "Hour": 4, "Minute": 0],
            ["Day": 12, "Hour": 1, "Minute": 0]
        ] as [[String: Any]])
        XCTAssertEqual(
            ScheduleCalculator.nextRun(of: many, after: date("2026-11-11 09:00"), calendar: calendar),
            date("2026-11-12 01:00")
        )
        XCTAssertEqual(ScheduleCalculator.launchdSchedules(["Minute": 0]).first?.hours, nil)
        XCTAssertTrue(ScheduleCalculator.launchdSchedules("bogus").isEmpty)
    }
}

final class ScheduleAnnotationTests: XCTestCase {
    func testLaunchdDictionaryBecomesCronAndDescription() {
        let expressions = ScheduleCalculator.cronExpressions(fromLaunchd: ["Hour": 3, "Minute": 15])
        XCTAssertEqual(expressions, ["15 3 * * *"])
        XCTAssertEqual(ScheduleCalculator.describe(cron: "15 3 * * *"), "每天 03:15")
        XCTAssertEqual(ScheduleCalculator.describe(cron: "0 4 * * 0"), "每周日 04:00")
        XCTAssertEqual(ScheduleCalculator.describe(cron: "0 1 12 * *"), "每月 12 日 01:00")
        XCTAssertEqual(ScheduleCalculator.describe(cron: "7 * * * *"), "每小时第 07 分")
        XCTAssertEqual(ScheduleCalculator.describe(cron: "*/5 * * * *"), "Cron：*/5 * * * *")
    }

    func testAnnotateEstimatesIntervalFromLastRunAndSkipsDisabled() {
        let now = Date(timeIntervalSince1970: 10_000)
        var item = ServiceItem(
            id: "a", name: "a", sourceType: .launchAgent, scope: .user, label: "a",
            lastRunAt: Date(timeIntervalSince1970: 2_000),
            triggers: [TriggerInfo(kind: .startInterval, summary: "每 3600 秒运行", expression: "3600")]
        )
        XCTAssertEqual(ScheduleCalculator.annotate(item, now: now).triggers?.first?.nextRunAt,
                       Date(timeIntervalSince1970: 12_800))

        item.disabled = true
        XCTAssertNil(ScheduleCalculator.annotate(item, now: now).triggers?.first?.nextRunAt)
    }

    func testAnnotateCronIsExact() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let item = ServiceItem(
            id: "c", name: "c", sourceType: .cron, scope: .user,
            triggers: [TriggerInfo(kind: .cron, summary: "", expression: "0 12 * * *")]
        )
        let next = ScheduleCalculator.annotate(item, now: Date(timeIntervalSince1970: 0), calendar: calendar)
            .triggers?.first?.nextRunAt
        XCTAssertEqual(next, Date(timeIntervalSince1970: 12 * 3600))
    }
}

final class LogWindowTests: XCTestCase {
    @MainActor
    func testLogWindowFollowsInterval() {
        func item(_ triggers: [TriggerInfo]) -> ServiceItem {
            ServiceItem(id: "x", name: "x", sourceType: .launchAgent, scope: .user, triggers: triggers)
        }
        XCTAssertEqual(DashboardViewModel.logWindowHours(for: item([TriggerInfo(kind: .startInterval, summary: "", expression: "3600")])), 2)
        XCTAssertEqual(DashboardViewModel.logWindowHours(for: item([TriggerInfo(kind: .startInterval, summary: "", expression: "60")])), 1)
        XCTAssertEqual(DashboardViewModel.logWindowHours(for: item([TriggerInfo(kind: .startInterval, summary: "", expression: "86400")])), 24)
        XCTAssertEqual(DashboardViewModel.logWindowHours(for: item([TriggerInfo(kind: .calendar, summary: "", expression: "0 3 * * *")])), 24)
    }

    func testLogLineParsing() {
        let output = "Timestamp               Ty Process[PID:TID]\n2026-11-11 08:32:34.600 Df launchd[1:11175de] [gui/501 [100015]:] service inactive: com.x\n"
        let parsed = LaunchdLogQuery.lastActivity(in: output)
        XCTAssertNotNil(parsed?.0)
        XCTAssertTrue(parsed?.1.contains("service inactive") == true)
    }
}
