import Foundation

/// 用户记作业的习惯：某些写法固定指向某门课。
///
/// 这些规则来自机主本人的课表现实——物理老师发打印的卷子、计算机布置习题册页码、
/// ESL 全是雅思（作文和口语音频两类）、EL 是文学分析、数学几乎不留作业。
/// 纯靠语义猜不出来：实测「计算机练习册 25 26 27页」在没有这些规则时会被判成 Math 或
/// Other Subjects，而「卷子」几乎永远落到 Math（中文语境里「卷子」确实常连着数学）。
///
/// **这不是在客户端发明分类或科目的合法值**：学科名和课程都仍然来自 Calendar 目录，
/// 查不到就整条跳过。这里只描述「用户会怎么写」。
///
/// 将来应该挪到后端——`courses` 表有 `notes` 字段，只是 `GET /api/course-catalog`
/// 目前不返回它。挪过去之后这份内置表就可以退成兜底。
struct CourseHabit {
    /// 写进提示词给模型看的写法，中英混写，让它认得用户的口语。
    let wording: String
    /// 这些写法指向的学科名，必须与 Calendar 目录里的名字一致。
    let subjectName: String
    /// 同一学科下有多门课时，用这个片段定位具体课程；为空则靠「该学科只有一门课」
    /// 或当天课表来定。
    let courseNeedle: String?
    /// app 侧判断输入是否命中的关键词。比 `wording` 保守：宁可漏，不可错。
    let keywords: [String]

    static let builtIn: [CourseHabit] = [
        .init(wording: "卷子 / 试卷 — a printed paper",
              subjectName: "Physics", courseNeedle: nil,
              keywords: ["卷子", "试卷"]),
        .init(wording: "习题册 / 练习册 / any page number like 「25 26 27页」or「p30」",
              subjectName: "CS", courseNeedle: nil,
              keywords: ["习题册", "练习册"]),
        .init(wording: "雅思作文 / 作文 / a writing task",
              subjectName: "English", courseNeedle: "雅思写作",
              keywords: ["作文"]),
        .init(wording: "口语 / 音频 / 录音",
              subjectName: "English", courseNeedle: "雅思口语",
              keywords: ["口语", "音频", "录音"]),
        .init(wording: "文学分析 / 分析小说、诗、文本",
              subjectName: "English", courseNeedle: "EL",
              keywords: ["文学分析"])
    ]

    /// 几乎不留作业的学科。含糊的笔记不该往这里引——实测在没有这条负向提示时，
    /// 「卷子」「习题册」大量落到 Math（中文语境里「卷子」确实常连着数学）。
    static let rarelyAssignsHomework = ["Math"]

    /// 页码是计算机作业的标志，但写法太多（「25 26 27页」「p30-32」「第 30 页」），
    /// 列不完，用正则认。
    static let pageNumberPattern = #"(第\s*)?\d+\s*[-~至到]?\s*\d*\s*页|\b[pP](ages?|\.)?\s*\d+"#

    static func mentionsPageNumber(_ input: String) -> Bool {
        input.range(of: pageNumberPattern, options: .regularExpression) != nil
    }

    /// 输入命中了哪一条习惯。按内置顺序取第一条，规则之间刻意不重叠。
    static func matching(_ input: String, in habits: [CourseHabit] = builtIn) -> CourseHabit? {
        if let direct = habits.first(where: { habit in
            habit.keywords.contains { input.localizedCaseInsensitiveContains($0) }
        }) {
            return direct
        }
        // 页码只对计算机那条生效。
        if mentionsPageNumber(input) {
            return habits.first { $0.subjectName == "CS" }
        }
        return nil
    }
}

/// 用户的「论文」是独立的科研项目，和课堂上的「作文」是两回事。
///
/// 两个词只差一个字，模型分不开：把区别写进提示词之后，「论文 Introduction 完成」
/// 修好了，「雅思作文」却整个掉进了 Research（实测合并测试集 45→41）。字面判断比
/// 让模型理解可靠，所以这一层放在 app 里。
///
/// 优先级**低于课程字面命中**——「经济学的论文」是 AS经济 的课业，不是科研论文。
enum ResearchMarkers {
    static let words = ["论文", "查重", "投递", "选题", "文献综述", "导师"]

    static func matches(_ input: String) -> Bool {
        words.contains { input.contains($0) }
    }
}

/// 「下节课交」这类说法：截止时间就是那门课的下一次上课。
///
/// 这是**确定性的**——课表已经在 `CourseOccurrence` 里了，算得出具体时刻，
/// 没有理由让模型去猜一个日期（何况实测它会把提示词里的当前时间抄走）。
/// 推不出课程、或者课表里没有下一次上课时，保持时间正则的结果不变。
enum NextLessonMarkers {
    static let words = ["下节课", "下一节课", "下次课", "下堂课", "下节", "next lesson", "next class"]

    static func matches(_ input: String) -> Bool {
        words.contains { input.localizedCaseInsensitiveContains($0) }
    }
}

/// 从一句话里认出页码，写成备注文案。
///
/// 机主记计算机作业就是写页码（「cs练习册 25 26 27」「习题册 p30-32」），
/// 这些数字是作业内容本身，丢在原文里、草稿上什么都不留的话，等他打开这条
/// Deadline 时还得回去翻自己当初写了什么。备注是它该待的地方。
///
/// **不交给模型**：页码是字面信息，抄错一位就是做错作业，正则比模型可靠。
enum PageNumbers {
    /// 出现这些词时，光秃秃的数字也按页码认——「cs练习册 25 26 27」没写「页」。
    static let workbookWords = ["练习册", "习题册", "workbook"]

    /// 一串页码的写法：`30-32`、`30~32`、`25 26 27`、`25,26,27`、`25、26`。
    private static let run = #"\d{1,3}\s*[-~至到]\s*\d{1,3}|\d{1,3}(?:\s*[,，、]\s*\d{1,3}|\s+\d{1,3})*"#

    /// 明确带页码标记的写法，优先按这些锚点取，免得把句子里别的数字当成页码。
    private static var anchored: [String] {
        ["(\(run))\\s*页", "第\\s*(\(run))\\s*页?", "[pP](?:ages?|\\.)?\\s*(\(run))"]
    }

    /// 返回给备注用的文案，例如 `P25, 26, 27` 或 `P30-32`；认不出就是 nil。
    static func note(from input: String) -> String? {
        guard let raw = rawRun(in: input) else { return nil }
        let numbers = raw.split(whereSeparator: { !$0.isNumber }).map(String.init)
        guard !numbers.isEmpty else { return nil }
        // 范围写法保留成范围：「p30-32」写成 P30-32 比 P30, 32 准确——那是 3 页不是 2 页。
        if numbers.count == 2, raw.range(of: #"[-~至到]"#, options: .regularExpression) != nil {
            return "P\(numbers[0])-\(numbers[1])"
        }
        return "P" + numbers.joined(separator: ", ")
    }

    private static func rawRun(in input: String) -> String? {
        for pattern in anchored {
            if let hit = capture(pattern, in: input) { return hit }
        }
        // 没有页码标记时，只有出现了习题册这类词才敢认，而且要求**至少两个数字**——
        // 「练习册 25」里的 25 也可能是题号，单个数字猜错的代价大于收益。
        guard workbookWords.contains(where: { input.localizedCaseInsensitiveContains($0) }) else { return nil }
        let runs = matches(run, in: input)
            .filter { $0.split(whereSeparator: { !$0.isNumber }).count >= 2 }
        return runs.max { $0.count < $1.count }
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
