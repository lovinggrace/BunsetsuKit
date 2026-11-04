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
        var matrix: [[Int]: [[ConjItem]]] = [:]
        for pos in posi {
            guard let posId = posIndex[pos], let rules = rules[posId], !rules.isEmpty,
                  !ConjugationConstants.doNotConjugate.contains(pos) else { continue }
            for r in readings {
                for rule in rules where conjTypes == nil || conjTypes!.contains(rule.conj) {
                    let key = [posId, rule.conj]
                    if matrix[key] == nil {
                        matrix[key] = Array(repeating: [], count: 4)
                        order.append((posId, rule.conj))
                    }
                    let item = ConjItem(text: constructConjugation(r.text, rule), kanjiFlag: r.kanji,
                                        reading: r.text, ord: r.ord, onum: rule.onum)
                    matrix[key]![(rule.neg ? 2 : 0) + (rule.fml ? 1 : 0)].insert(item, at: 0)
                }
            }
        }
        return order.map { ($0, matrix[[$0.0, $0.1]]!) }
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

    /// A possible dictionary form of a conjugated text.
    struct BaseCandidate: Hashable {
        let text: String
        let posId: Int
    }

    /// conjugated ending (euphonic change + okurigana) -> rules producing it
    private(set) lazy var suffixIndex: [String: [InverseRule]] = {
        var d: [String: [InverseRule]] = [:]
        for (posId, list) in rules {
            for r in list {
                for (euph, kana) in [(r.euphr, true), (r.euphk, false)] {
                    let stem = r.stem + (euph.isEmpty ? 0 : 1)
                    let key = euph + r.okuri
                    let inv = InverseRule(posId: posId, conj: r.conj, stem: stem, kana: kana)
                    if !(d[key]?.contains { $0.posId == inv.posId && $0.conj == inv.conj && $0.stem == inv.stem && $0.kana == kana } ?? false) {
                        d[key, default: []].append(inv)
                    }
                }
            }
        }
        return d
    }()

    private(set) lazy var maxSuffixLength: Int = suffixIndex.keys.map(\.len).max() ?? 0

    /// Possible dictionary form endings: pos-id -> length -> endings (filled from the database)
    var endings: [Int: [Int: Set<String>]] = [:]

    /// Candidate dictionary forms of a conjugated text.
    func baseCandidates(_ text: String, conjTypes: Set<Int>? = nil, posIds: Set<Int>? = nil) -> Set<BaseCandidate> {
        var result = Set<BaseCandidate>()
        let l = text.len
        for sl in 0...min(l, maxSuffixLength) {
            let suffix = text.sub(l - sl)
            guard let invs = suffixIndex[suffix] else { continue }
            let prefix = text.sub(0, l - sl)
            for inv in invs {
                if let conjTypes, !conjTypes.contains(inv.conj) { continue }
                if let posIds, !posIds.contains(inv.posId) { continue }
                for e in endings[inv.posId]?[inv.stem] ?? [] {
                    let base = prefix + e
                    // construct-conjugation chooses the euphonic change by the last two characters
                    if testWord(base.sub(max(0, base.len - 2)), .kana) == inv.kana {
                        result.insert(BaseCandidate(text: base, posId: inv.posId))
                    }
                }
            }
        }
        return result
    }
}
