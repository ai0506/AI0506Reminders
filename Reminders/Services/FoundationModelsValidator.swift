import Foundation

/// 校验通过后的提案：名字都已经换成目录里的真实对象。
struct CheckedProposal {
    var title: String
    var category: DeadlineCategory?
    var subject: DeadlineSubject?
    var tags: [DeadlineTag]
    var priority: DeadlinePriority
    var reason: String
}

/// 模型输出的守门人。
///
/// `@Generable` 只保证**结构**合法，不保证 `categoryName` 真在清单里——探针里
/// 7 个用例有 3 个编造了标签名（"Reading"、"Report"、"friends"、"rest"，
/// 其中后两个还是从提示词的分类说明文字里抄走的）。所以这一层是必需的。
enum Validator {
    enum Outcome {
        case accepted(CheckedProposal)
        /// 附带要发回给模型的具体抱怨。
        case rejected(String)
    }

    /// 错误分两级。
    ///
    /// **重试**：模型编了不存在的分类或学科，或者学科与分类对不上。这些字段是必填的，
    /// 且直接决定后端 `course_id` / `subject_id` 的校验能否通过，猜一个填上去只会在
    /// 提交时吃 400，不如让模型重想一次。
    ///
    /// **直接修**：标签编错、大小写不对、超出数量。标签是可选的，丢掉非法项剩下的仍然
    /// 可用；为一个标签重跑一轮推理，用户要多等的时间远大于它的价值。
    static func validate(_ proposal: DraftProposal, catalog: PromptCatalog) -> Outcome {
        guard let category = catalog.category(named: proposal.categoryName) else {
            let names = catalog.categories.map(\.name).joined(separator: ", ")
            return .rejected(PromptBuilder.complaint(
                "\"\(proposal.categoryName)\" is not in the Categories list. Choose one of: \(names)."
            ))
        }

        var subject: DeadlineSubject?
        let requestedSubject = proposal.subjectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 模型表达「没有学科」的方式不统一：nil、空串、"无" 都出现过。
        if !requestedSubject.isEmpty, !isNullish(requestedSubject) {
            guard let matched = catalog.subject(named: requestedSubject) else {
                let names = catalog.academicSubjects.map(\.name).joined(separator: ", ")
                return .rejected(PromptBuilder.complaint(
                    names.isEmpty
                        ? "There are no subjects to choose from. Leave subjectName empty."
                        : "\"\(requestedSubject)\" is not in the Subjects list. Choose one of: \(names), or leave subjectName empty."
                ))
            }
            // 学科必须挂在模型自己选的那个分类下，否则写入时后端会拒。
            guard matched.categoryID == category.id else {
                return .rejected(PromptBuilder.complaint(
                    "Subject \"\(matched.name)\" does not belong to category \"\(category.name)\". "
                    + "Either choose the category that subject belongs to, or leave subjectName empty."
                ))
            }
            subject = matched
        }

        return .accepted(CheckedProposal(
            title: cleanTitle(proposal.title),
            category: category,
            subject: category.kind == "academics" ? subject : nil,
            tags: usableTags(proposal.tagNames, catalog: catalog),
            priority: proposal.priority.model,
            reason: proposal.reason
        ))
    }

    /// 重试次数用完后的兜底：能查到的留下，查不到的丢掉，绝不猜。
    static func salvage(_ proposal: DraftProposal, catalog: PromptCatalog) -> CheckedProposal {
        let category = catalog.category(named: proposal.categoryName)
        let subject = proposal.subjectName.flatMap { catalog.subject(named: $0) }
        let resolved = category ?? catalog.categories.first
        return CheckedProposal(
            title: cleanTitle(proposal.title),
            category: resolved,
            subject: resolved?.kind == "academics" && subject?.categoryID == resolved?.id ? subject : nil,
            tags: usableTags(proposal.tagNames, catalog: catalog),
            priority: proposal.priority.model,
            reason: proposal.reason
        )
    }

    /// 标签：大小写规范化、丢弃清单外的、去重，最后卡后端的 5 个上限。
    /// 客户端不卡的话超了要等提交才吃 400。
    private static func usableTags(_ names: [String], catalog: PromptCatalog) -> [DeadlineTag] {
        var seen = Set<String>()
        return names
            .compactMap { catalog.tag(named: $0) }
            .filter { seen.insert($0.id).inserted }
            .prefix(5)
            .map { $0 }
    }

    private static func cleanTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isNullish(_ value: String) -> Bool {
        ["无", "null", "none", "n/a", "-"].contains(value.lowercased())
    }
}
