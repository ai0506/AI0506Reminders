import Foundation

enum MockAIDeadlineParser {
    static func parse(
        input: String,
        categories: [DeadlineCategory],
        tags: [DeadlineTag],
        subjects: [DeadlineSubject] = [],
        now: Date = .now
    ) -> AIParseResult {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()
        let fallbackCategory = categories.first ?? DeadlineCategory.all[0]
        let category = matchingCategory(in: cleaned, lower: lower, categories: categories) ?? fallbackCategory
        let selectedTags = LocalDraftRules.tags(in: cleaned, catalog: tags)
        let subject = matchingSubject(in: cleaned, lower: lower, subjects: subjects)
        let timing = dueTiming(in: cleaned, lower: lower, now: now)
        let priority = LocalDraftRules.priority(for: cleaned)
        let title = title(from: cleaned)

        return AIParseResult(
            originalText: cleaned,
            draft: DeadlineDraft(
                title: title.isEmpty ? "新建截止事项" : title,
                detail: "根据你的输入在本地生成。请在创建前检查并调整。",
                dueDate: timing.date,
                allDay: timing.isAllDay,
                category: category,
                subject: category.kind == "academics" ? subject : nil,
                tags: selectedTags,
                priority: priority
            ),
            confidence: timing.wasExplicit ? 0.92 : 0.76
        )
    }

    /// 时间解析的复用入口。
    ///
    /// `FoundationModelsDeadlineParser` 刻意不让模型读日期——实测端侧模型会把
    /// prompt 里的「Now: Friday 16:50」当成答案抄走（"明天下午三点" 解出 16 点、
    /// 五个用例的星期全塌缩成 Friday）。这里的正则是确定性的，中英文都覆盖，
    /// 比模型准得多，所以两个解析器共用同一套时间判断。
    static func timing(in input: String, now: Date = .now) -> (date: Date, isAllDay: Bool, wasExplicit: Bool) {
        dueTiming(in: input, lower: input.lowercased(), now: now)
    }

    /// 标题提炼的复用入口：模型没给出标题时的兜底。
    static func fallbackTitle(from input: String) -> String {
        title(from: input)
    }

    private static func matchingCategory(in input: String, lower: String, categories: [DeadlineCategory]) -> DeadlineCategory? {
        if let exact = categories.first(where: { lower.contains($0.name.lowercased()) || input.contains($0.name) }) { return exact }
        if lower.contains("research") || input.contains("研究") {
            return category(matching: ["research", "研究"], in: categories)
        }
        if lower.contains("project") || input.contains("项目") {
            return category(matching: ["project", "项目"], in: categories)
        }
        if lower.contains("physics") || input.contains("物理") {
            return category(matching: ["physics", "物理", "academics", "学业"], in: categories)
        }
        if lower.contains("math") || input.contains("数学") {
            return category(matching: ["math", "数学", "academics", "学业"], in: categories)
        }
        if lower.contains("cs") || input.contains("计算机") {
            return category(matching: ["cs", "computer", "计算机", "academics", "学业"], in: categories)
        }
        return nil
    }

    private static func category(matching aliases: [String], in categories: [DeadlineCategory]) -> DeadlineCategory? {
        categories.first { category in aliases.contains { category.name.localizedCaseInsensitiveContains($0) } }
    }

    private static func matchingSubject(in input: String, lower: String, subjects: [DeadlineSubject]) -> DeadlineSubject? {
        subjects.first { subject in
            lower.contains(subject.name.lowercased()) || input.contains(subject.name) ||
            (lower.contains("physics") || input.contains("物理")) && subject.name.localizedCaseInsensitiveContains("physics") ||
            (lower.contains("math") || input.contains("数学")) && subject.name.localizedCaseInsensitiveContains("math") ||
            (lower.contains("computer") || lower.contains("cs") || input.contains("计算机")) && (subject.name.localizedCaseInsensitiveContains("computer") || subject.name.localizedCaseInsensitiveContains("cs"))
        }
    }

    /// 相对日期一律按 `Calendar.shanghai` 算，不跟设备时区走。理由见那个常量上的注释。
    private static func dueTiming(in input: String, lower: String, now: Date) -> (date: Date, isAllDay: Bool, wasExplicit: Bool) {
        let calendar = Calendar.shanghai
        let baseDay: Date
        if input.contains("明天") || lower.contains("tomorrow") {
            baseDay = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        } else if input.contains("后天") || lower.contains("day after tomorrow") {
            baseDay = calendar.date(byAdding: .day, value: 2, to: now) ?? now
        } else if let weekday = weekday(in: input, lower: lower) {
            let today = calendar.component(.weekday, from: now)
            let offset = (weekday - today + 7) % 7
            baseDay = calendar.date(byAdding: .day, value: offset, to: now) ?? now
        } else {
            baseDay = calendar.date(byAdding: .day, value: 2, to: now) ?? now
        }

        guard let time = explicitTime(in: input, lower: lower) else {
            return (calendar.startOfDay(for: baseDay), true, input.contains("明天") || input.contains("后天") || lower.contains("tomorrow"))
        }
        let dated = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: baseDay) ?? baseDay
        return (dated, false, true)
    }

    private static func explicitTime(in input: String, lower: String) -> (hour: Int, minute: Int)? {
        let englishPattern = #"\b([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)\b"#
        if let match = firstMatch(englishPattern, in: lower), let hour = Int(match[1]) {
            let minute = Int(match[2]) ?? 0
            let meridiem = match[3]
            let normalizedHour = meridiem == "pm" ? (hour == 12 ? 12 : hour + 12) : (hour == 12 ? 0 : hour)
            return (normalizedHour, minute)
        }

        let chinesePattern = #"(?:(上午|下午|晚上|中午))?([0-9一二三四五六七八九十]{1,3})(?::([0-9]{2}))?点(?:([0-9]{1,2})分)?"#
        if let match = firstMatch(chinesePattern, in: input), let rawHour = chineseHour(match[2]) {
            let minute = Int(match[4]) ?? Int(match[3]) ?? 0
            let period = match[1]
            let hour: Int
            if (period == "下午" || period == "晚上" || period == "中午") && rawHour < 12 { hour = rawHour + 12 }
            else { hour = rawHour }
            return (hour, minute)
        }
        return nil
    }

    private static func title(from input: String) -> String {
        let firstClause = input.components(separatedBy: CharacterSet(charactersIn: "，,。.!！？"))[0]
        var value = firstClause
        if let range = value.range(of: "\\b(?:tomorrow|today|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\\b.*$", options: [.regularExpression, .caseInsensitive]) {
            value.removeSubrange(range)
        }
        value = value.replacingOccurrences(of: #"(?:今天|明天|后天|周[一二三四五六日天]|星期[一二三四五六日天])"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?:(?:上午|下午|晚上|中午))?[0-9一二三四五六七八九十]{1,3}(?::[0-9]{2})?点(?:[0-9]{1,2}分)?(?:前|后)?"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\b(?:at|by|before)\b.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func weekday(in input: String, lower: String) -> Int? {
        let chinese: [Character: Int] = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
        if let match = firstMatch(#"(?:周|星期)([一二三四五六日天])"#, in: input), let day = match[1].first {
            return chinese[day]
        }
        let english = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]
        return english.first(where: { lower.contains($0.key) })?.value
    }

    private static func chineseHour(_ value: String) -> Int? {
        if let number = Int(value) { return number }
        let mapping: [String: Int] = [
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6,
            "七": 7, "八": 8, "九": 9, "十": 10, "十一": 11, "十二": 12
        ]
        return mapping[value]
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }
}
