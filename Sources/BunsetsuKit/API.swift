// Public API (ichiran.lisp / romanize.lisp entry points)

import Foundation

public enum RomanizeOutput: Sendable {
    case romaji(RomanizationMethod)
    /// the original text (`:text`)
    case text
    /// kana without hints (`:kana`)
    case kana
}

extension Ichiran {
    func romanizeWordInfo(_ wi: WordInfo, _ output: RomanizeOutput) -> String {
        switch output {
        case .text: return wi.text
        case .kana: return mapWordInfoKana(wi) { stripHints($0) }
        case .romaji(let m): return mapWordInfoKana(wi) { m.romanizeWord($0, originalSpelling: wi.text, normalize: false) }
        }
    }

    /// Romanizes a sentence (`romanize`). With `withInfo`, also returns (romanized word, dictionary info) pairs.
    public func romanize(_ input: String, method: RomanizationMethod = .default) -> String {
        romanizeWithInfo(input, output: .romaji(method)).text
    }

    public func romanizeWithInfo(_ input: String, output: RomanizeOutput = .romaji(.default)) -> (text: String, info: [(String, String)]) {
        synchronized {
            var parts: [String] = []
            var info: [(String, String)] = []
            for (type, text) in basicSplit(normalize(input)) {
                if type == .word {
                    for wi in simpleSegment(text) {
                        let rom = romanizeWordInfo(wi, output)
                        info.append((rom, wordInfoStr(wi)))
                        parts.append(rom)
                    }
                } else {
                    parts.append(text)
                }
            }
            return (joinParts(parts), info)
        }
    }

    /// `romanize*`: detailed segmentation as the JSON produced by `ichiran-cli -f`.
    public func romanizeDetailed(_ input: String, method: RomanizationMethod = .default, limit: Int = 5) -> JSONValue {
        synchronized {
            .array(basicSplit(normalize(input)).map { type, text -> JSONValue in
                guard type == .word else { return .string(text) }
                return .array(dictSegment(text, limit: limit).map { words, score in
                    .array([.array(words.map { wi in
                        .array([.string(romanizeWordInfo(wi, .romaji(method))), wordInfoGlossJSON(wi), .nilValue])
                    }), .int(score)])
                })
            })
        }
    }

    /// Segments Japanese text (`dict-segment`).
    public func segment(_ text: String, limit: Int = 5) -> [(words: [WordInfo], score: Int)] {
        synchronized { dictSegment(text, limit: limit) }
    }

    /// Best segmentation (`simple-segment`).
    public func simpleSegment(text: String) -> [WordInfo] {
        synchronized { simpleSegment(text) }
    }

    /// JMdict `seq` numbers of the dictionary forms of a segmented word: a conjugated form maps to the entry
    /// it was conjugated from, and a compound to its components (first component first).
    public func dictionaryForms(of wi: WordInfo) -> [Int] {
        synchronized { dictionaryFormSeqs(wi) }
    }

    func dictionaryFormSeqs(_ wi: WordInfo) -> [Int] {
        var result: [Int] = []
        func add(_ seq: Int) { if !result.contains(seq) { result.append(seq) } }
        if !wi.components.isEmpty {
            for component in wi.components { dictionaryFormSeqs(component).forEach(add) }
            return result
        }
        func flatten(_ s: WordSeq) -> [Int] {
            switch s {
            case .none: return []
            case .int(let i): return [i]
            case .list(let l): return l.flatMap(flatten)
            }
        }
        for seq in flatten(wi.seq) {
            let conjs = getConjData(seq, ConjFilter(wi.conjugations))
            if conjs.isEmpty { add(seq) } else { conjs.forEach { add($0.from) } }
        }
        return result
    }

    /// Whether the database contains glosses (databases built with `includeGlosses: false` do not).
    public var hasGlosses: Bool {
        synchronized { db.column("SELECT EXISTS (SELECT 1 FROM gloss)").first?.int == 1 }
    }

    /// Dictionary information for a word (`word-info-str`).
    public func describe(_ wi: WordInfo) -> String { synchronized { wordInfoStr(wi) } }

    /// Gloss JSON for a word (`word-info-gloss-json`).
    public func glossJSON(_ wi: WordInfo, rootOnly: Bool = false) -> JSONValue { synchronized { wordInfoGlossJSON(wi, rootOnly: rootOnly) } }

    /// Looks up a single word (`find-word-info`).
    public func lookup(_ text: String, reading: String? = nil, rootOnly: Bool = false) -> [WordInfo] {
        synchronized { findWordInfo(text, reading: reading, rootOnly: rootOnly) }
    }
}
