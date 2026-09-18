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
