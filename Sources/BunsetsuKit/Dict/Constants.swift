// Runtime constants from dict-errata.lisp and dict-grammar.lisp

enum Conj {
    static let adverbial = 50
    static let adjectiveStem = 51
    static let negativeStem = 52
    static let causativeSu = 53
    static let adjectiveLiterary = 54
}

enum Errata {
    /// seq of words that aren't really words, like suffixes etc.
    static let skipWords: Set<Int> = [
        2822120, // ても良い
        2013800, // ちゃう
        2108590, // とく
        2029040, // ば
        2428180, // い
        2654250, // た
        2561100, // うまいな
        2210270, // ませんか
        2210710, // ましょうか
        2257550, // ない
        2210320, // ません
        2017560, // たい
        2394890, // とる
        2194000, // であ
        2568000, // れる/られる
        2537250, // しようとする
        2760890, // 三箱
        2831062, // てる
        2831063, // てく
        2029030, // ものの
        2568020, // せる
        900000, // たそう
        2827357, // まう
    ]

    /// Words that only have meaning when they're final
    static let finalPrt: [Int] = [
        2017770, // かい
        2425930, // なの
        2130430, // け っけ
        2029130, // ぞ
        2834812, // ぜ
        2718360, // がな
        2201380, // わい
        2722170, // のう
        2751630, // かいな
    ]

    /// Particles that are final, but also have other uses
    static let semiFinalPrt: [Int] = finalPrt + [
        2029120, // さ
        2086640, // し
        2029110, // な
        2029080, // ね
        2029100, // わ
    ]

    static let copulae: [Int] = [2089020] // だ

    /// Particles that don't get final bonus
    static let nonFinalPrt: [Int] = [2139720] // ん

    /// Words that get no kanji break penalty
    static let noKanjiBreakPenalty: [Int] = [
        1169870, // 飲む
        1198360, // 会議
        1277450, // 好き
        2028980, // で
        1423000, // 着る
        1164690, // 一段
        1587040, // 言う
        2827864, // なので
    ]

    static let forceKanjiBreak: [String] = ["です"]

    /// Words that do not cause kanji break
    static let noKanjiBreak: [String] = ["日置"] // problematic with 一日置く

    /// A conjugation form pattern: (pos?, type, neg, fml) with nil meaning :any
    struct ConjForm {
        let pos: String?
        let type: Int
        let neg: Bool?
        let fml: Bool?
        let anyNeg: Bool
        let anyFml: Bool

        init(pos: String? = nil, _ type: Int, neg: Bool? = nil, fml: Bool? = nil) {
            self.pos = pos
            self.type = type
            self.neg = neg
            self.fml = fml
            anyNeg = neg == nil
            anyFml = fml == nil
        }
    }

    static let skipConjForms: [ConjForm] = [
        ConjForm(10, neg: true),
        ConjForm(3, neg: true, fml: true),
        ConjForm(pos: "vs-s", 5),
    ]

    static let weakConjForms: [ConjForm] = [
        ConjForm(Conj.adjectiveStem),
        ConjForm(Conj.negativeStem),
        ConjForm(Conj.causativeSu),
        ConjForm(Conj.adjectiveLiterary),
        ConjForm(9, neg: true),
    ]

    static func testConjProp(_ prop: ConjProp, _ forms: [ConjForm]) -> Bool {
        forms.contains { f in
            if let pos = f.pos, pos != prop.pos { return false }
            guard f.type == prop.conjType else { return false }
            if !f.anyNeg, prop.neg != f.neg { return false }
            if !f.anyFml, prop.fml != f.fml { return false }
            return true
        }
    }

    static func skipByConjData(_ conjData: [ConjData]) -> Bool {
        !conjData.isEmpty && conjData.allSatisfy { testConjProp($0.prop, skipConjForms) }
    }

    static let conjDescriptionExtra: [Int: String] = [
        Conj.adverbial: "Adverbial",
        Conj.adjectiveStem: "Adjective Stem",
        Conj.negativeStem: "Negative Stem",
        Conj.causativeSu: "Causative (~su)",
        Conj.adjectiveLiterary: "Old/literary form",
    ]
}

/// Descriptions of conjugation types (conj.csv from JMdictDB, plus errata).
enum ConjDescriptions {
    static let table: [Int: String] = [
        1: "Non-past", 2: "Past (~ta)", 3: "Conjunctive (~te)", 4: "Provisional (~eba)",
        5: "Potential", 6: "Passive", 7: "Causative", 8: "Causative-Passive",
        9: "Volitional", 10: "Imperative", 11: "Conditional (~tara)", 12: "Alternative (~tari)",
        13: "Continuative (~i)",
    ]

    static func get(_ id: Int) -> String {
        Errata.conjDescriptionExtra[id] ?? table[id] ?? "Conjugation \(id)"
    }
}

/// Lisp-style stable merge sort accepting a non strict-weak predicate (like SBCL's `sort` on lists).
func lispStableSort<T>(_ list: [T], _ less: (T, T) -> Bool) -> [T] {
    if list.count <= 1 { return list }
    let mid = list.count / 2
    let a = lispStableSort(Array(list[..<mid]), less)
    let b = lispStableSort(Array(list[mid...]), less)
    var r: [T] = []
    r.reserveCapacity(list.count)
    var i = 0, j = 0
    while i < a.count, j < b.count {
        if less(b[j], a[i]) { r.append(b[j]); j += 1 } else { r.append(a[i]); i += 1 }
    }
    r.append(contentsOf: a[i...])
    r.append(contentsOf: b[j...])
    return r
}

/// `compare-common` (nil stands for NIL / no common value)
func compareCommon(_ c1: Int?, _ c2: Int?) -> Bool {
    guard let c2 else { return c1 != nil }
    if c2 == 0 { return (c1 ?? 0) > 0 }
    if let c1, c1 > 0 { return c1 < c2 }
    return false
}
