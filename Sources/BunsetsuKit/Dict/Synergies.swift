// Port of synergies, penalties and segfilters (dict-grammar.lisp)

import Foundation

typealias SegFilter = (Ichiran, Segment) -> Bool

let nounParticles: [Int] = [
    2028920, // は
    2028930, // が
    2028990, // に
    2028980, // で
    2029000, // へ
    1007340, // だけ
    1579080, // ごろ
    1525680, // まで
    2028940, // も
    1582300, // など
    2215430, // には
    1469800, // の
    1009990, // のみ
    2029010, // を
    1005120, // さえ
    2034520, // でさえ
    1005120, // すら
    1008490, // と
    1008530, // とか
    1008590, // として
    2028950, // とは
    2028960, // や
    1009600, // にとって
]

func filterIsNoun(_ ich: Ichiran, _ seg: Segment) -> Bool {
    let (k, p, c, l) = seg.info.kpcl
    if (l || k || (p && c)) && !Set(["n", "n-adv", "n-t", "adj-na", "n-suf", "pn"]).isDisjoint(with: seg.info.posi) {
        return true
    }
    return seg.word is CounterText && !seg.info.seqSet.isEmpty
}

func filterIsPos(_ posList: [String], _ test: @escaping (Bool, Bool, Bool, Bool) -> Bool) -> SegFilter {
    { _, seg in
        let (k, p, c, l) = seg.info.kpcl
        return test(k, p, c, l) && !Set(posList).isDisjoint(with: seg.info.posi)
    }
}

func filterInSeqSet(_ seqs: [Int]) -> SegFilter {
    let set = Set(seqs)
    return { _, seg in !set.isDisjoint(with: seg.info.seqSet) }
}

func filterInSeqSet(_ seqs: Int...) -> SegFilter { filterInSeqSet(seqs) }

/// Same as above but checks that the word is not compound
func filterInSeqSetSimple(_ seqs: [Int]) -> SegFilter {
    let set = Set(seqs)
    return { _, seg in !(seg.word is CompoundText) && !set.isDisjoint(with: seg.info.seqSet) }
}

func filterIsConjugation(_ conjType: Int) -> SegFilter {
    { _, seg in seg.info.conj.contains { $0.prop.conjType == conjType } }
}

func filterIsCompoundEnd(_ seqs: Int...) -> SegFilter {
    { ich, seg in
        guard let l = ich.seqList(seg.word), let last = l.last else { return false }
        return seqs.contains(last)
    }
}

func filterIsCompoundEndText(_ texts: String...) -> SegFilter {
    { ich, seg in
        guard let c = seg.word as? CompoundText, !c.words.isEmpty else { return false }
        return texts.contains(ich.getText(c.lastWord))
    }
}

func complement(_ f: @escaping SegFilter) -> SegFilter { { !f($0, $1) } }

// MARK: - Synergies

struct SynergyDef {
    let left: SegFilter
    let right: SegFilter
    let description: String
    let connector: String
    let score: (SegmentList, SegmentList) -> Int
}

func syn(_ left: @escaping SegFilter, _ right: @escaping SegFilter, _ description: String, score: Int, connector: String) -> SynergyDef {
    SynergyDef(left: left, right: right, description: description, connector: connector, score: { _, _ in score })
}

/// Definition order; the Lisp list is built with pushnew and therefore reversed.
let synergyDefs: [SynergyDef] = [
    SynergyDef(left: filterIsNoun, right: filterInSeqSet(nounParticles), description: "noun+prt", connector: " ",
               score: { _, r in 10 + 4 * (r.end - r.start) }),
    syn(filterIsNoun, filterInSeqSet(2089020), "noun+da", score: 10, connector: " "), // だ
    syn(filterInSeqSet(1469800, 2139720), filterInSeqSet(2089020, 1007370, 1928670), "no da/desu", score: 15, connector: " "),
    syn(filterInSeqSet(2137720), filterInSeqSet(2140410), "sou na n da", score: 50, connector: " "),
    syn(filterIsPos(["adj-no"]) { k, p, c, l in k || l || (p && c) }, filterInSeqSet(1469800), "no-adjective", score: 15, connector: " "),
    syn(filterIsPos(["adj-na"]) { k, p, c, l in k || l || (p && c) }, filterInSeqSet(2029110, 2028990), "na-adjective", score: 15, connector: " "),
    SynergyDef(left: filterIsPos(["adv-to"]) { k, p, _, l in k || l || p }, right: filterInSeqSet(1008490),
               description: "to-adverb", connector: " ", score: { l, _ in 10 + 10 * (l.end - l.start) }),
    syn(filterIsNoun, filterInSeqSet(1620400, 2083570), "suffix-chu", score: 12, connector: "-"),
    syn(filterIsNoun, filterInSeqSet(1416220), "suffix-tachi", score: 10, connector: "-"),
    syn(filterIsNoun, filterInSeqSet(1361140), "suffix-buri", score: 40, connector: ""),
    syn(filterIsNoun, filterInSeqSet(1375260), "suffix-sei", score: 12, connector: ""),
    syn(filterInSeqSet(1270190), filterIsPos(["n"]) { k, _, _, l in k || l }, "o+noun", score: 10, connector: ""),
    syn(filterInSeqSet(2242840, 1922780, 2423740), filterIsPos(["n"]) { k, _, _, _ in k }, "kanji prefix+noun", score: 15, connector: ""), // 未 不
    syn(filterIsCompoundEnd(2028920), filterInSeqSet(1000730, 1612750, 1409110, 2829697, 1587610), "shicha ikenai", score: 50, connector: " "),
    syn(filterInSeqSet(1005460), { _, seg in seg.info.conj.contains { $0.prop.neg == true } }, "shika+neg", score: 50, connector: " "),
    syn(filterInSeqSet(1469800), filterInSeqSet(1432920), "no toori", score: 50, connector: " "),
    syn(filterIsPos(["ctr"]) { _, _, _, _ in true }, filterInSeqSet(2854117, 2084550), "", score: 20, connector: ""),
].reversed()

// MARK: - Penalties

struct PenaltyDef {
    let serial: Bool
    let left: (Ichiran, SegmentList) -> Bool
    let right: (Ichiran, SegmentList) -> Bool
    let description: String
    let score: Int
    let connector: String
}

func filterShortKana(_ len: Int, except: [String] = []) -> (Ichiran, SegmentList) -> Bool {
    { ich, sl in
        guard let seg = sl.segments.first else { return false }
        return sl.end - sl.start <= len && !seg.info.kpcl.k && !except.contains(ich.getText(seg))
    }
}

let penaltyDefs: [PenaltyDef] = [
    PenaltyDef(serial: false, left: filterShortKana(1), right: filterShortKana(1, except: ["と"]),
               description: "short", score: -9, connector: " "),
    PenaltyDef(serial: true, left: { ich, sl in sl.segments.contains { filterInSeqSet(Errata.semiFinalPrt)(ich, $0) } },
               right: { _, _ in true }, description: "semi-final not final", score: -15, connector: " "),
].reversed()

// MARK: - Segfilters

struct SegFilterDef {
    let left: SegFilter
    let right: SegFilter
    let allowFirst: Bool
}

let auxVerbs: [Int] = [1342560] // 初める/そめる

let honorifics: [Int] = [1247260] // 君

/// Definition order; reversed like the Lisp pushnew list.
let segfilterDefs: [SegFilterDef] = [
    SegFilterDef(left: filterIsConjugation(13), right: filterInSeqSet(auxVerbs), allowFirst: false), // aux-verb
    SegFilterDef(left: complement(filterInSeqSet(2221640)), right: filterInSeqSet(1577980), allowFirst: true), // tsu-iru
    SegFilterDef(left: complement(filterInSeqSetSimple(nounParticles)), right: filterInSeqSet(2139720, 2849370, 2849387), allowFirst: true), // n
    SegFilterDef(left: filterInSeqSet(2029010), right: filterInSeqSet(2087020), allowFirst: false), // wokarasu
    SegFilterDef(left: { _, _ in false }, right: filterIsCompoundEndText("ちゃい", "いか", "とか", "とき", "い"), allowFirst: false), // badend
    // some of adj-ix words end with 好い which produces a confusing 好き conjugation
    SegFilterDef(left: { _, _ in false }, right: { ich, seg in
        filterIsConjugation(Conj.adjectiveLiterary)(ich, seg) && ich.getText(seg).hasScalarSuffix("好き")
    }, allowFirst: false), // sukiyoki
    SegFilterDef(left: complement(filterIsCompoundEndText("いろ")), right: { ich, seg in ich.getText(seg).startsWith("く") }, allowFirst: true), // roku
    SegFilterDef(left: complement(filterIsCompoundEnd(2029120)), right: { ich, seg in ich.getText(seg).startsWith("え") }, allowFirst: true), // sae
    SegFilterDef(left: complement(filterIsCompoundEnd(2028920)), right: filterInSeqSet(1529520, 1296400, 2139720), allowFirst: true), // janai
    SegFilterDef(left: complement(filterInSeqSet(1469800)), right: filterInSeqSet(1601080), allowFirst: true), // nohayamete
    // split と before 思う 言う
    SegFilterDef(left: complement(filterInSeqSet(2837117)), right: filterInSeqSet(1589350, 1587040), allowFirst: true), // toomou
    SegFilterDef(left: complement(filterInSeqSet(1008490)), right: filterInSeqSet(2086960), allowFirst: true), // totte
    SegFilterDef(left: { _, seg in
        let s = seg.info.seqSet
        return !s.contains(2089020) || s.contains(2028980) // だ で
    }, right: filterInSeqSet(1157170, 2424740, 1305070), allowFirst: true), // dashi
    // 出 followed by 来る or 来てる
    SegFilterDef(left: complement(filterInSeqSet(1896380, 2422860)), right: filterInSeqSet(2830009, 1547720), allowFirst: true), // dekiru
    SegFilterDef(left: complement(filterInSeqSet(nounParticles)), right: filterInSeqSet(honorifics), allowFirst: false), // honorific
    SegFilterDef(left: complement(filterInSeqSet(2028940)), right: filterInSeqSet(1009980), allowFirst: true), // mononi
].reversed()

typealias SegPair = (left: SegmentList?, right: SegmentList)

extension Ichiran {
    func getSynergies(_ l: SegmentList, _ r: SegmentList) -> [[PathItem]] {
        var result: [[PathItem]] = []
        guard l.end == r.start else { return result }
        for def in synergyDefs {
            let left = l.segments.filter { def.left(self, $0) }
            let right = r.segments.filter { def.right(self, $0) }
            if !left.isEmpty && !right.isEmpty {
                let s = Synergy(description: def.description, connector: def.connector, score: def.score(l, r),
                                start: l.end, end: r.start)
                result.append([.list(r.with(right)), .synergy(s), .list(l.with(left))])
            }
        }
        return result
    }

    func getPenalties(_ l: SegmentList, _ r: SegmentList) -> [PathItem] {
        for def in penaltyDefs {
            if (!def.serial || l.end == r.start) && def.left(self, l) && def.right(self, r) {
                let s = Synergy(description: def.description, connector: def.connector, score: def.score,
                                start: l.end, end: r.start)
                return [.list(r), .synergy(s), .list(l)]
            }
        }
        return [.list(r), .list(l)]
    }

    private func applySegfilter(_ def: SegFilterDef, _ l: SegmentList?, _ r: SegmentList) -> [SegPair] {
        let satisfiesRight = r.segments.filter { def.right(self, $0) }
        let contradictsRight = r.segments.filter { !def.right(self, $0) }
        if satisfiesRight.isEmpty || (def.allowFirst && l == nil) {
            return [(l, r)]
        }
        guard let l, l.end == r.start else {
            return contradictsRight.isEmpty ? [] : [(l, r.with(contradictsRight))]
        }
        let satisfiesLeft = l.segments.filter { def.left(self, $0) }
        let contradictsLeft = l.segments.filter { !def.left(self, $0) }
        if contradictsLeft.isEmpty { return [(l, r)] }
        var result: [SegPair] = contradictsRight.isEmpty ? [] : [(l, r.with(contradictsRight))]
        if !satisfiesLeft.isEmpty {
            result.insert((l.with(satisfiesLeft), r.with(satisfiesRight)), at: 0)
        }
        return result
    }

    func applySegfilters(_ l: SegmentList?, _ r: SegmentList) -> [SegPair] {
        var splits: [SegPair] = [(l, r)]
        for def in segfilterDefs {
            splits = splits.flatMap { applySegfilter(def, $0.left, $0.right) }
        }
        return splits
    }
}
