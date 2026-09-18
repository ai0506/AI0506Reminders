import Foundation

/// 不交给模型的那几个字段：优先级和标签。
///
/// V1 让模型一起判这两项，代价很直接——`@Generable` 枚举的首项偏置让 priority 一度
/// 五个用例全是 high；标签则被编造了三次，其中 "friends"、"rest" 还是从提示词的分类
/// 说明文字里抄回来的。这两个字段都有确定的字面证据可依，交给模型只是在制造噪声。
///
/// 设备端路径和本地规则路径共用这里，避免两条路径给出不同的结果。
enum LocalDraftRules {
    /// 只认明确的紧急字样。没有证据就是 `.default`——
    /// 宁可让用户自己抬优先级，也不要让草稿页上半数事项都标成高优先。
    static let urgencyMarkers = ["urgent", "important", "high", "重要", "高优先"]

    static func priority(for text: String) -> DeadlinePriority {
        let lower = text.lowercased()
        let hit = urgencyMarkers.contains { marker in
            marker.allSatisfy(\.isASCII) ? lower.contains(marker) : text.contains(marker)
        }
        return hit ? .high : .default
    }

    /// 标签按**名字**或别名的字面命中来选，没有命中就是空的。
    ///
    /// 按名字不按 id：id 是后端生成的（可能是 "tag-exam"，也可能是 UUID），
    /// 拿它做 key 在真实数据上一条都命中不了；名字才是用户会写进句子里的那个词。
    /// 最后卡后端 5 个的硬上限，客户端不卡的话超了要等提交才吃 400。
    static func tags(in text: String, catalog: [DeadlineTag]) -> [DeadlineTag] {
        let lower = text.lowercased()
        var seen = Set<String>()
        return catalog
            .filter { tag in
                lower.contains(tag.name.lowercased())
                    || text.contains(tag.name)
                    || aliases(for: tag).contains { lower.contains($0) }
            }
            .filter { seen.insert($0.id).inserted }
            .prefix(5)
            .map { $0 }
    }

    static func aliases(for tag: DeadlineTag) -> [String] {
        switch tag.name.lowercased() {
        case "exam": ["exam", "考试"]
        case "urgent": ["urgent", "紧急"]
        case "writing": ["writing", "写作"]
        case "review": ["review", "复习"]
        // 别名表**刻意只抄 V1 的原样**。往这里加词看着都合理（比如 homework → 作业），
        // 但每加一条都会改变真实输入的标签结果，而标签是给用户筛选用的，加错了他才发现。
        // 要加就跟着回归集一起加。
        default: []
        }
    }
}
