import Foundation

/// 草稿的可信状态——**由来源推出来，不是模型自评的，而且永远不显示成百分比**。
///
/// 界面上那句「解析置信度 70%」已经删掉了，模型输出里的自评字段也一并删了：
/// 拿回来的基本是 0.85 / 0.9 这种没有信息量的值，既说不出哪一格可能错，
/// 也不随证据变化，还白占输出 token。这里换成记录「时间是怎么来的、路线有多强的证据、
/// 走没走降级」，再把这些翻译成一句用户能照着做的话。
///
/// 所以这个类型对外只给 `headline` 和 `itemsToCheck`，**不要**再给它加一个
/// 折算成 0–1 或百分比的属性——那等于把刚删掉的东西换个来源装回去。
struct DraftConfidence: Equatable {
    /// 截止时间是怎么定的。
    enum TimeBasis: Equatable {
        /// 原文写了具体时刻。
        case explicitTime
        /// 原文只写了哪天。
        case explicitDay
        /// 原文没写，用的默认值。
        case defaulted
    }

    /// 归档路线是怎么定的。
    enum RouteBasis: Equatable {
        case course(RoutingEvidence)
        case subject
        case categoryOnly
        /// 证据不足，路线没定。
        case unresolved
    }

    /// 这次解析实际走完了哪条路。
    enum Path: Equatable {
        /// 两次调用都一次过。
        case model
        /// Pass B 选了候选表外的 key，纠错重试后才拿到合法结果。
        case modelAfterRetry
        /// Pass A 与 Pass B 的理解对不上，保留了草稿但不该显得有把握。
        case conflicted
        /// 模型不可用或调用失败，整条走的本地规则。
        case localRulesOnly
    }

    var timeBasis: TimeBasis
    var routeBasis: RouteBasis
    var path: Path

    /// 用户需要动手检查的地方。为空表示可以直接创建。
    var itemsToCheck: [String] {
        var items: [String] = []
        switch routeBasis {
        case .unresolved: items.append("分类")
        case .categoryOnly, .subject, .course: break
        }
        if case .course(let evidence) = routeBasis, evidence == .courseFinishedToday {
            // 「今天上过这门课」是最弱的一条证据：同一天上过好几门课时，它更接近猜测。
            items.append("课程")
        }
        if timeBasis == .defaulted { items.append("截止时间") }
        if path == .conflicted { items.append("标题和分类") }
        return items
    }

    var needsCheck: Bool { !itemsToCheck.isEmpty || path != .model }

    /// 草稿页上那一行。说清楚**凭什么**这么填，而不是给个百分比。
    var headline: String {
        if path == .localRulesOnly { return "本地规则解析，请逐项检查" }
        if path == .conflicted { return "两次判断不一致，请检查分类和课程" }
        if case .unresolved = routeBasis { return "没有把握的分类，请自己选" }

        let reason: String
        switch routeBasis {
        case .course(let evidence): reason = evidence.explanation
        case .subject: reason = "归到学科，没挂具体课程"
        case .categoryOnly: reason = "只归到分类"
        case .unresolved: reason = ""
        }
        if timeBasis == .defaulted { return "\(reason)；没识别出截止时间" }
        if path == .modelAfterRetry { return "\(reason)；重试后才定下来，建议看一眼" }
        return reason
    }

    static func timeBasis(isAllDay: Bool, wasExplicit: Bool) -> TimeBasis {
        if !isAllDay { return .explicitTime }
        return wasExplicit ? .explicitDay : .defaulted
    }

    static func routeBasis(for candidate: RoutingCandidate?) -> RouteBasis {
        guard let candidate, !RoutingCandidateBuilder.isUnresolved(candidate) else { return .unresolved }
        if candidate.course != nil { return .course(candidate.evidence) }
        return candidate.subject != nil ? .subject : .categoryOnly
    }
}
