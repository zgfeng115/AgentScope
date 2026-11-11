import Foundation

/// A cron / launchd calendar schedule; `nil` fields mean "any".
public struct CalendarSchedule: Hashable, Sendable {
    public var minutes: Set<Int>?
    public var hours: Set<Int>?
    public var days: Set<Int>?
    public var months: Set<Int>?
    /// 0 = Sunday ... 6 = Saturday (7 is normalised to 0).
    public var weekdays: Set<Int>?

    public init(
        minutes: Set<Int>? = nil,
        hours: Set<Int>? = nil,
        days: Set<Int>? = nil,
        months: Set<Int>? = nil,
        weekdays: Set<Int>? = nil
    ) {
        self.minutes = minutes
        self.hours = hours
        self.days = days
        self.months = months
        self.weekdays = weekdays.map { Set($0.map { $0 % 7 }) }
    }
}

public enum ScheduleCalculator {
    /// Parses a 5-field cron expression or an `@keyword`. `@reboot` has no calendar time and returns nil.
    public static func cronSchedule(_ expression: String) -> CalendarSchedule? {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "@hourly": return CalendarSchedule(minutes: [0])
        case "@daily", "@midnight": return CalendarSchedule(minutes: [0], hours: [0])
        case "@weekly": return CalendarSchedule(minutes: [0], hours: [0], weekdays: [0])
        case "@monthly": return CalendarSchedule(minutes: [0], hours: [0], days: [1])
        case "@yearly", "@annually": return CalendarSchedule(minutes: [0], hours: [0], days: [1], months: [1])
        default: break
        }
        let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5,
              let minutes = cronField(fields[0], range: 0...59),
              let hours = cronField(fields[1], range: 0...23),
              let days = cronField(fields[2], range: 1...31),
              let months = cronField(fields[3], range: 1...12),
              let weekdays = cronField(fields[4], range: 0...7)
        else { return nil }
        return CalendarSchedule(minutes: minutes, hours: hours, days: days, months: months, weekdays: weekdays)
    }

    /// Returns `.some(nil)` for "*" (any), `nil` for unparseable.
    static func cronField(_ field: String, range: ClosedRange<Int>) -> Set<Int>?? {
        if field == "*" { return .some(nil) }
        var values: Set<Int> = []
        for part in field.split(separator: ",") {
            let stepParts = part.split(separator: "/", maxSplits: 1)
            let step = stepParts.count == 2 ? Int(stepParts[1]) : 1
            guard let step, step > 0 else { return nil }
            let base = String(stepParts[0])
            let bounds: ClosedRange<Int>
            if base == "*" {
                bounds = range
            } else if let dash = base.firstIndex(of: "-") {
                guard let low = Int(base[..<dash]), let high = Int(base[base.index(after: dash)...]), low <= high else { return nil }
                bounds = low...high
            } else {
                guard let single = Int(base) else { return nil }
                bounds = stepParts.count == 2 ? single...range.upperBound : single...single
            }
            guard range.contains(bounds.lowerBound), range.contains(bounds.upperBound) else { return nil }
            values.formUnion(stride(from: bounds.lowerBound, through: bounds.upperBound, by: step))
        }
        return .some(values)
    }

    /// launchd `StartCalendarInterval`: one dictionary or an array of them.
    public static func launchdSchedules(_ value: Any?) -> [CalendarSchedule] {
        let dictionaries: [[String: Any]]
        if let single = value as? [String: Any] {
            dictionaries = [single]
        } else if let many = value as? [[String: Any]] {
            dictionaries = many
        } else {
            return []
        }
        return dictionaries.map { entry in
            func set(_ key: String) -> Set<Int>? { (entry[key] as? Int).map { [$0] } }
            return CalendarSchedule(
                minutes: set("Minute"),
                hours: set("Hour"),
                days: set("Day"),
                months: set("Month"),
                weekdays: set("Weekday")
            )
        }
    }

    /// First matching minute strictly after `date`, searching up to ~4 years ahead.
    public static func nextRun(
        of schedule: CalendarSchedule,
        after date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        let minutes = (schedule.minutes ?? Set(0...59)).sorted()
        let hours = (schedule.hours ?? Set(0...23)).sorted()
        guard let start = calendar.date(byAdding: .minute, value: 1, to: date),
              let startMinute = calendar.dateInterval(of: .minute, for: start)?.start
        else { return nil }
        let startDay = calendar.startOfDay(for: startMinute)

        for dayOffset in 0..<(366 * 4 + 1) {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startDay) else { return nil }
            guard dayMatches(schedule, day, calendar: calendar) else { continue }
            for hour in hours {
                for minute in minutes {
                    guard let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                          calendar.component(.hour, from: candidate) == hour
                    else { continue }
                    if candidate >= startMinute { return candidate }
                }
            }
        }
        return nil
    }

    public static func nextRun(
        of schedules: [CalendarSchedule],
        after date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        schedules.compactMap { nextRun(of: $0, after: date, calendar: calendar) }.min()
    }

    private static func dayMatches(_ schedule: CalendarSchedule, _ day: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.month, .day, .weekday], from: day)
        if let months = schedule.months, !months.contains(components.month ?? -1) { return false }
        let dayOK = schedule.days.map { $0.contains(components.day ?? -1) }
        let weekdayOK = schedule.weekdays.map { $0.contains((components.weekday ?? 1) - 1) }
        switch (dayOK, weekdayOK) {
        case (nil, nil): return true
        case (let d?, nil): return d
        case (nil, let w?): return w
        case (let d?, let w?): return d || w   // cron and launchd: either restriction matches
        }
    }
}

extension ScheduleCalculator {
    /// launchd calendar dictionaries rendered as cron expressions ("15 3 * * *"), so both share one evaluator.
    public static func cronExpressions(fromLaunchd value: Any?) -> [String] {
        launchdSchedules(value).map { schedule in
            [schedule.minutes, schedule.hours, schedule.days, schedule.months, schedule.weekdays]
                .map { field in field.map { $0.sorted().map(String.init).joined(separator: ",") } ?? "*" }
                .joined(separator: " ")
        }
    }

    /// "每天 03:15" / "每周日 04:00" / "每月 12 日 01:00"; falls back to the raw expression.
    public static func describe(cron expression: String) -> String {
        guard let schedule = cronSchedule(expression) else {
            return expression == "@reboot" ? "开机时运行" : "Cron：\(expression)"
        }
        guard let minute = schedule.minutes, minute.count == 1 else {
            if schedule.minutes == nil, schedule.hours == nil, schedule.days == nil,
               schedule.months == nil, schedule.weekdays == nil { return "每分钟" }
            return "Cron：\(expression)"
        }
        let minuteText = String(format: "%02d", minute.first!)
        guard let hours = schedule.hours else {
            return schedule.days == nil && schedule.weekdays == nil && schedule.months == nil
                ? "每小时第 \(minuteText) 分" : "Cron：\(expression)"
        }
        guard hours.count == 1 else { return "Cron：\(expression)" }
        let time = String(format: "%02d:", hours.first!) + minuteText
        let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]
        switch (schedule.days, schedule.weekdays, schedule.months) {
        case (nil, nil, nil):
            return "每天 \(time)"
        case (nil, let weekdays?, nil):
            return "每周" + weekdays.sorted().map { weekdayNames[$0] }.joined(separator: "、") + " \(time)"
        case (let days?, nil, nil):
            return "每月 " + days.sorted().map(String.init).joined(separator: "、") + " 日 \(time)"
        default:
            return "Cron：\(expression)"
        }
    }

    /// Fills `TriggerInfo.nextRunAt` for interval / calendar / cron triggers. Disabled items never run next.
    public static func annotate(_ item: ServiceItem, now: Date = Date(), calendar: Calendar = .current) -> ServiceItem {
        guard let triggers = item.triggers, !triggers.isEmpty else { return item }
        let inactive = item.disabled || [.disabled, .stale].contains(item.state)
        var annotated = item
        annotated.triggers = triggers.map { trigger in
            guard !inactive else { return trigger.withNextRun(nil) }
            switch trigger.kind {
            case .calendar, .cron:
                let schedules = (trigger.expression ?? "")
                    .split(separator: ";")
                    .compactMap { cronSchedule(String($0)) }
                return trigger.withNextRun(nextRun(of: schedules, after: now, calendar: calendar))
            case .startInterval:
                guard let seconds = Double(trigger.expression ?? ""), seconds > 0,
                      let last = item.lastRunAt else { return trigger }
                let elapsed = max(0, now.timeIntervalSince(last))
                let periods = (elapsed / seconds).rounded(.down) + 1
                return trigger.withNextRun(last.addingTimeInterval(periods * seconds))
            default:
                return trigger
            }
        }
        return annotated
    }
}

extension TriggerInfo {
    func withNextRun(_ date: Date?) -> TriggerInfo {
        TriggerInfo(kind: kind, summary: summary, expression: expression, nextRunAt: date)
    }

    /// Calendar and cron schedules are exact; interval-based ones are estimates from the last run.
    public var nextRunIsEstimate: Bool { kind == .startInterval }
}
