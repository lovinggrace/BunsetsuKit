// Conjugation rules (conjo.csv of JMdictDB + errata), shared by the builder and the runtime
// generator of conjugated forms.

import Foundation

struct ConjugationRule {
    var pos: Int
    var conj: Int
    var neg: Bool
    var fml: Bool
    var onum: Int
    var stem: Int
    var okuri: String
    var euphr: String
    var euphk: String
}

/// A conjugated reading of a cell of the conjugation matrix.
struct ConjItem {
    let text: String
    let kanjiFlag: Bool
    let reading: String
    let ord: Int
    let onum: Int
}

/// A reading of a word to conjugate.
struct ConjSource {
    let text: String
    let ord: Int
    let kanji: Bool
}

/// `construct-conjugation`
func constructConjugation(_ word: String, _ rule: ConjugationRule) -> String {
    let iskana = testWord(word.sub(max(0, word.len - 2)), .kana)
    let stem = rule.stem + ((iskana && !rule.euphr.isEmpty) || (!iskana && !rule.euphk.isEmpty) ? 1 : 0)
    return word.sub(0, max(0, word.len - stem)) + (iskana ? rule.euphr : rule.euphk) + rule.okuri
}

enum ConjugationConstants {
    static let doNotConjugate: Set<String> = ["n", "vs", "adj-na"]
    static let doNotConjugateSeq: Set<Int> = [2765070, 2835284]
    static let posWithConjRules: Set<String> = ["adj-i", "adj-ix", "cop-da", "v1", "v1-s", "v5aru",
                                                "v5b", "v5g", "v5k", "v5k-s", "v5m", "v5n", "v5r", "v5r-i", "v5s",
                                                "v5t", "v5u", "v5u-s", "vk", "vs-s", "vs-i"]
    static let secondaryConjugationTypesFrom: [Int] = [5, 6, 7, 8, Conj.causativeSu]
    static let secondaryConjugationTypes: [Int] = [2, 3, 4, 9, 10, 11, 12, 13]
    static let secondaryConjugationTypesFromSet = Set(secondaryConjugationTypesFrom)
    static let secondaryConjugationTypesSet = Set(secondaryConjugationTypes)
}

final class Conjugator {
    let rules: [Int: [ConjugationRule]]
    let posIndex: [String: Int]
    let posByIndex: [Int: String]

    init(rules: [Int: [ConjugationRule]], posIndex: [String: Int]) {
        self.rules = rules
        self.posIndex = posIndex
        var by: [Int: String] = [:]
        for (k, v) in posIndex { by[v] = k }
        posByIndex = by
    }

    /// `conjugate-entry-inner`: (pos-id, conj-id) -> 2x2 matrix [neg][fml] (row-major), in insertion order
    func matrix(posi: [String], readings: [ConjSource], conjTypes: [Int]? = nil) -> [((Int, Int), [[ConjItem]])] {
        var order: [(Int, Int)] = []
        var cells: [[[ConjItem]]] = []
        var cellIndex: [Int: Int] = [:]
        // per reading: its scalars and whether it ends in kana (`construct-conjugation` chooses the euphonic change by that)
        let prepared = readings.map { r -> (scalars: [Unicode.Scalar], kana: Bool) in
            let sc = r.text.scalars
            return (sc, !sc.isEmpty && sc.suffix(2).allSatisfy { charMatches($0, .kana) })
        }
        for pos in posi {
            guard let posId = posIndex[pos], let rules = rules[posId], !rules.isEmpty,
                  !ConjugationConstants.doNotConjugate.contains(pos) else { continue }
            for (ri, r) in readings.enumerated() {
                let (sc, iskana) = prepared[ri]
                // the reading without its last n characters
                var stems: [String?] = [nil, nil, nil, nil]
                for rule in rules where conjTypes == nil || conjTypes!.contains(rule.conj) {
                    let key = posId << 16 | rule.conj
                    let cell: Int
                    if let c = cellIndex[key] {
                        cell = c
                    } else {
                        cell = cells.count
                        cellIndex[key] = cell
                        cells.append(Array(repeating: [], count: 4))
                        order.append((posId, rule.conj))
                    }
                    let euph = iskana ? rule.euphr : rule.euphk
                    let cut = rule.stem + (euph.isEmpty ? 0 : 1)
                    let stem: String
                    if cut >= 0, cut < stems.count, let s = stems[cut] {
                        stem = s
                    } else {
                        stem = String(scalars: sc[0..<max(0, sc.count - cut)])
                        if cut >= 0, cut < stems.count { stems[cut] = stem }
                    }
                    let item = ConjItem(text: stem + euph + rule.okuri, kanjiFlag: r.kanji, reading: r.text, ord: r.ord, onum: rule.onum)
                    cells[cell][(rule.neg ? 2 : 0) + (rule.fml ? 1 : 0)].insert(item, at: 0)
                }
            }
        }
        return order.indices.map { (order[$0], cells[$0]) }
    }

    // MARK: - Deinflection

    struct InverseRule {
        let posId: Int
        let conj: Int
        /// number of characters removed from the dictionary form
        let stem: Int
        /// the rule applies to words ending in kana (euphr) or not (euphk)
        let kana: Bool
    }

    /// conjugated ending (euphonic change + okurigana) -> rules producing it
    private(set) lazy var suffixIndex: [TextKey: [InverseRule]] = {
        var d: [TextKey: [InverseRule]] = [:]
        for (posId, list) in rules {
            for r in list {
                for (euph, kana) in [(r.euphr, true), (r.euphk, false)] {
                    let stem = r.stem + (euph.isEmpty ? 0 : 1)
                    let key = TextKey(euph + r.okuri)
                    let inv = InverseRule(posId: posId, conj: r.conj, stem: stem, kana: kana)
                    if !(d[key]?.contains { $0.posId == inv.posId && $0.conj == inv.conj && $0.stem == inv.stem && $0.kana == kana } ?? false) {
                        d[key, default: []].append(inv)
                    }
                }
            }
        }
        return d
    }()

    private(set) lazy var maxSuffixLength: Int = suffixIndex.keys.map(\.text.len).max() ?? 0

    /// A possible ending of a dictionary form.
    struct Ending {
        let text: String
        let scalars: [Unicode.Scalar]
    }

    /// Possible dictionary form endings: pos-id -> length -> endings (filled from the database)
    private(set) var endings: [Int: [Int: [Ending]]] = [:]

    /// Endings must be added once each.
    func addEnding(_ text: String, pos: Int, length: Int) {
        endings[pos, default: [:]][length, default: []].append(Ending(text: text, scalars: text.scalars))
    }

    /// A way to undo a conjugation: replace the conjugated ending by `ending`.
    struct InverseForm {
        let ending: Ending
        /// the rules apply to words ending in kana (euphr) or not (euphk)
        let kana: Bool
        /// the (pos, conjugation type) pairs of the rules
        var uses: [(posId: Int, conj: Int)]
        /// the distinct pos of `uses`
        var posIds: [Int]
    }

    /// conjugated ending -> ways to undo it (rules giving the same dictionary form are merged)
    private(set) lazy var inverseIndex: [TextKey: [InverseForm]] = {
        var d: [TextKey: [InverseForm]] = [:]
        for (key, invs) in suffixIndex {
            var forms: [InverseForm] = []
            for inv in invs {
                for e in endings[inv.posId]?[inv.stem] ?? [] {
                    let i = forms.firstIndex { $0.kana == inv.kana && $0.ending.text == e.text } ?? {
                        forms.append(InverseForm(ending: e, kana: inv.kana, uses: [], posIds: []))
                        return forms.count - 1
                    }()
                    forms[i].uses.append((inv.posId, inv.conj))
                    if !forms[i].posIds.contains(inv.posId) { forms[i].posIds.append(inv.posId) }
                }
            }
            d[key] = forms
        }
        return d
    }()

    /// Candidate dictionary forms of a conjugated text (only those `accept` returns true for), with their possible pos.
    func baseCandidates(_ text: String, conjTypes: Set<Int>? = nil, posIds: Set<Int>? = nil,
                        accept: ((String) -> Bool)? = nil) -> [TextKey: [Int]] {
        var result: [TextKey: [Int]] = [:]
        let sc = text.scalars
        let l = sc.count
        // string indices of the scalars
        var indices = Array(text.unicodeScalars.indices)
        indices.append(text.endIndex)
        for sl in 0...min(l, maxSuffixLength) {
            guard let forms = inverseIndex[TextKey(String(text[indices[l - sl]...]))] else { continue }
            var prefix: Substring? = nil
            for f in forms {
                var pos = f.posIds
                if conjTypes != nil || posIds != nil {
                    pos = []
                    for u in f.uses where (conjTypes == nil || conjTypes!.contains(u.conj)) && (posIds == nil || posIds!.contains(u.posId)) {
                        if !pos.contains(u.posId) { pos.append(u.posId) }
                    }
                    if pos.isEmpty { continue }
                }
                // construct-conjugation chooses the euphonic change by the last two characters of the word
                var n = 0, kana = true
                for c in f.ending.scalars.suffix(2) {
                    n += 1
                    kana = kana && charMatches(c, .kana)
                }
                if n < 2, l - sl > 0 {
                    for c in sc[max(0, l - sl - (2 - n))..<(l - sl)] {
                        n += 1
                        kana = kana && charMatches(c, .kana)
                    }
                }
                guard (n > 0 && kana) == f.kana else { continue }
                if prefix == nil { prefix = text[..<indices[l - sl]] }
                let base = String(prefix!) + f.ending.text
                if let accept, !accept(base) { continue }
                let key = TextKey(base)
                if var have = result[key] {
                    for p in pos where !have.contains(p) { have.append(p) }
                    result[key] = have
                } else {
                    result[key] = pos
                }
            }
        }
        return result
    }
}
