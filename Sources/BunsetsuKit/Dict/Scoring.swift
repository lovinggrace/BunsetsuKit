// Port of the scoring part of dict.lisp (calc-score and friends)

import Foundation

enum LengthClass { case strong, weak, tail, ltail }

func lengthMultiplierCoeff(_ length: Int, _ cls: LengthClass) -> Int {
    let coeffs: [Int]
    switch cls {
    case .strong: coeffs = [1, 8, 24, 40, 60]
    case .weak: coeffs = [1, 4, 9, 16, 25, 36]
    case .tail: coeffs = [4, 9, 16, 24]
    case .ltail: coeffs = [4, 12, 18, 24]
    }
    if length > 0 && length <= coeffs.count { return coeffs[length - 1] }
    return length * (coeffs[coeffs.count - 1] / coeffs.count)
}

/// this must filter out ONLY bad kana spellings, and NOT filter out any kanji spellings
let scoreCutoff = 5
let gapPenalty = -500
func gapPenalty(_ start: Int, _ end: Int) -> Int { (end - start) * gapPenalty }

extension Ichiran {
    // MARK: caches

    /// seqs whose senses are all archaic, obscure or rare
    func loadArchBase() -> Set<Int> {
        Set(db.column("""
            SELECT sense.seq FROM sense
            LEFT JOIN sense_prop sp ON sp.sense_id = sense.id AND sp.tag = 'misc' AND sp.text IN ('arch', 'obsc', 'rare')
            GROUP BY sense.seq HAVING SUM(CASE WHEN sp.id IS NULL THEN 1 ELSE 0 END) = 0
            """).compactMap(\.int))
    }

    func loadIsArch() -> Set<Int> {
        let a1 = Array(archBase)
        var result = archBase
        for chunk in chunked(a1) {
            for s in db.column("SELECT DISTINCT seq FROM conjugation WHERE \"from\" IN \(placeholders(chunk.count))", chunk) {
                if let s = s.int { result.insert(s) }
            }
        }
        return result
    }

    func isArch(_ seq: Int) -> Bool {
        if isVirtual(seq) { return virtualEntry(seq)?.conjs.contains { archBase.contains($0.from) } ?? false }
        return isArchSet.contains(seq)
    }

    func getNonArchPosi(_ seqSet: [Int]) -> [String] {
        if seqSet.isEmpty { return [] }
        if let c = nonArchPosiCache[seqSet] { return c }
        let r = db.column("""
            SELECT DISTINCT sp1.text FROM sense_prop sp1
            LEFT JOIN sense_prop sp2 ON sp1.sense_id = sp2.sense_id AND sp2.tag = 'misc' AND sp2.text IN ('arch', 'obsc', 'rare')
            WHERE sp1.seq IN \(placeholders(seqSet.count)) AND sp1.tag = 'pos' AND sp2.id IS NULL
            ORDER BY sp1.text
            """, seqSet).compactMap(\.text)
        if nonArchPosiCache.count > 100_000 { nonArchPosiCache.removeAll() }
        nonArchPosiCache[seqSet] = r
        return r
    }

    // MARK: kanji break

    func kanjiBreakPenalty(_ kanjiBreak: [Int], _ score: Int, info: SegInfo?, text: String,
                           useLength: Int?, scoreMod: ScoreMod) -> Int {
        enum End { case both, beg, end }
        let end: End = kanjiBreak.count > 1 ? .both : (kanjiBreak.first == 0 ? .beg : .end)
        var bonus = 0
        let ratio = 2
        if let info {
            let posi = info.posi
            if !Set(info.seqSet).isDisjoint(with: Errata.noKanjiBreakPenalty)
                || (end == .beg && text.startsWith("す")) {
                // do not penalize second word of で/す break
                return score
            } else if posi.contains("vs-s") || posi.contains("v5s") {
                // these words have する endings which might lead to bad splits
                if let suru = getSuffixes(text).first(where: { $0.key == "suru" }), let kf = suru.kf {
                    let offset = moraLength(text) - moraLength(suru.substr)
                    let suffixScore = calcScore(kf, useLength: useLength.map { $0 - offset }, scoreMod: scoreMod).score
                    return min(score, suffixScore + 50)
                }
            } else if end == .beg && posi.contains("num") {
                bonus += 5
            } else if end == .beg && (posi.contains("suf") || posi.contains("n-suf")) {
                bonus += 10
            } else if end == .end && posi.contains("pref") {
                bonus += 12
            }
        }
        if score >= scoreCutoff {
            return max(scoreCutoff, (score + ratio - 1) / ratio + bonus)
        }
        return score
    }

    // MARK: calc-score

    func calcScore(_ reading: Word, final: Bool = false, useLength: Int? = nil,
                   scoreMod: ScoreMod = .int(0), kanjiBreak: [Int]? = nil) -> (score: Int, info: SegInfo?) {
        if let c = reading as? CompoundText {
            let base = c.effectiveScoreBase
            let ul = moraLength(c.text)
            var (score, info) = calcScore(base, useLength: ul, scoreMod: c.scoreMod)
            var inf = info ?? SegInfo()
            inf.conj = wordConjData(c)
            if let kanjiBreak {
                score = kanjiBreakPenalty(kanjiBreak, score, info: inf, text: getText(base), useLength: ul, scoreMod: c.scoreMod)
            }
            return (score, inf)
        }
        let ctrMode = reading is CounterText

        var score = 1
        var propScore = 0
        let kanjiP = wordType(reading) == .kanji
        let katakanaP = !kanjiP && countCharClass(trueText(reading), .katakanaUniq) > 0
        let text = getText(reading)
        let nKanji = countCharClass(text, .kanji)
        let len = max(1, moraLength(text))
        let seq = seqOf(reading)
        var ord = self.ord(reading)
        let entry = seq.flatMap(getEntry)
        let wc = conjugations(reading)
        let conjOnly = wc.isConjOnly
        let rootP = ctrMode || (!conjOnly && (entry?.rootP ?? false))
        var conjData = wordConjData(reading)

        var secondaryConjP = false
        if !conjData.isEmpty {
            if conjData.allSatisfy({ $0.via != nil }) {
                secondaryConjP = true
            } else {
                // delete all secondary conjugations from conj data
                conjData.removeAll { $0.via != nil }
            }
        }

        let conjOf = conjData.map(\.from)
        let conjProps = conjData.map(\.prop)
        let conjTypes = conjProps.map(\.conjType)
        let conjTypesP = rootP || useLength != nil
            || (!conjProps.isEmpty && !conjProps.allSatisfy { Errata.testConjProp($0, Errata.weakConjForms) })
        let seqSet: [Int] = seq.map { [$0] + conjOf } ?? []
        let spSeqSet: [Int] = (seq != nil && rootP && useLength == nil) ? [seq!] : seqSet
        let preferKana: [Int] = spSeqSet.isEmpty ? [] : db.column("""
            SELECT sense_id FROM sense_prop WHERE seq IN \(placeholders(spSeqSet.count)) AND tag = 'misc' AND text = 'uk' ORDER BY id
            """, spSeqSet).compactMap(\.int)
        let preferKanaP = !preferKana.isEmpty
        let isArch = spSeqSet.allSatisfy(self.isArch)
        let posi = ctrMode ? ["ctr"] : getNonArchPosi(seqSet)
        var common: Int? = conjOnly ? nil : self.common(reading)
        var commonOf = common
        var commonP = common != nil
        let particleP = posi.contains("prt")
        let semiFinalParticleP = seq.map(Errata.semiFinalPrt.contains) ?? false
        let nonFinalParticleP = seq.map(Errata.nonFinalPrt.contains) ?? false
        let pronounP = posi.contains("pn")
        let copDaP = !Set(seqSet).isDisjoint(with: Errata.copulae)
        let longThreshold: Int = {
            if kanjiP && !preferKanaP && ((rootP && conjData.isEmpty) || (useLength != nil && conjTypes.contains(13))) { return 2 }
            if commonP, let c = common, c > 0 && c < 10 { return 2 }
            if (conjTypes.contains(3) || conjTypes.contains(9)) && useLength == nil { return 4 }
            return 3
        }()
        let longP = len > longThreshold
        let noCommonBonus = particleP || !conjTypesP || (!longP && posi == ["int"])
        var primaryP = false
        var useLengthBonus = 0

        if !Set(seqSet).isDisjoint(with: Errata.skipWords)
            || (!final && seq.map(Errata.finalPrt.contains) == true)
            || (!rootP && Errata.skipByConjData(conjData)) {
            return (0, nil)
        }

        if !conjData.isEmpty && !(ord == 0 && commonP), let simple = reading as? SimpleText {
            let conjOfData = getOriginalText(simple, conjData: conjData).map { ($0.common, $0.ord) }
            if !conjOfData.isEmpty {
                if !commonP {
                    let conjOfCommon = conjOfData.compactMap(\.0)
                    if !conjOfCommon.isEmpty {
                        common = 0
                        commonP = true
                        commonOf = lispStableSort(conjOfCommon.map { Optional($0) }, compareCommon).first!
                    }
                }
                let conjOfOrd = conjOfData.map(\.1).min()!
                if conjOfOrd < ord { ord = conjOfOrd }
            }
        }

        if !isArch {
            primaryP = entry == nil
            if !primaryP, let entry {
                primaryP =
                    (preferKanaP && conjTypesP && !kanjiP && (!entry.primaryNokanji || nokanji(reading)))
                    || ((ord == 0 || copDaP) && (kanjiP || conjTypesP)
                        && ((kanjiP && !preferKanaP) || (commonP && pronounP) || entry.nKanji == 0))
                    || (preferKanaP && kanjiP && ord == 0
                        && db.query("SELECT id FROM sense WHERE id IN \(placeholders(preferKana.count)) AND ord = 0", preferKana).isEmpty)
            }
        }

        if primaryP {
            if longP { score += 10 }
            else if secondaryConjP && !kanjiP { score += 2 }
            else if commonP && conjTypesP { score += 5 }
            else if preferKanaP || entry == nil || entry!.nKanji == 0 { score += 3 }
            else { score += 2 }
        }
        if particleP && (final || !semiFinalParticleP) {
            score += 2
            if commonP { score += 2 + len }
            if final && !nonFinalParticleP {
                if primaryP { score += 5 } else if semiFinalParticleP { score += 2 }
            }
        }
        if commonP && !noCommonBonus, let c = common {
            var commonBonus: Int
            if secondaryConjP && useLength == nil {
                commonBonus = kanjiP && primaryP ? 4 : 2
            } else if longP || copDaP || (rootP && (kanjiP || (primaryP && len > 2))) {
                if c == 0 { commonBonus = 10 }
                else if !primaryP { commonBonus = max(15 - c, 10) }
                else { commonBonus = max(20 - c, 10) }
            } else if kanjiP { commonBonus = 8 }
            else if primaryP { commonBonus = 4 }
            else if len > 2 || (c > 0 && c < 10) { commonBonus = 3 }
            else { commonBonus = 2 }
            if commonBonus >= 10 && conjTypes.contains(10) { commonBonus -= 4 }
            score += commonBonus
        }
        if longP { score = max(len, score) }
        if kanjiP {
            score = max(isArch ? 3 : 5, score)
            if longP && (nKanji > 1 || len > 4) { score += 2 }
        }
        if ctrMode { score = max(5, score) }
        propScore = score
        score = propScore * (lengthMultiplierCoeff(len, (kanjiP || katakanaP) ? .strong : .weak)
                             + (nKanji > 1 ? (nKanji - 1) * 5 : 0))

        if let useLength {
            useLengthBonus += propScore * lengthMultiplierCoeff(useLength - len, (len > 3 && (kanjiP || katakanaP)) ? .ltail : .tail)
            useLengthBonus += scoreMod.apply(propScore, useLength - len)
            score += useLengthBonus
        }

        if !ctrMode, let simple = reading as? SimpleText, let split = getSplit(simple, conjOf) {
            if split.hasScore {
                score += split.score
            } else if split.hasPscore {
                let newPropScore = max(1, propScore + split.score)
                score = Int((Double(score * newPropScore) / Double(propScore)).rounded(.up))
                propScore = newPropScore
            } else if !split.parts.isEmpty {
                let nparts = split.parts.count
                var slen = 0, smlen = 0
                var total = 0
                for (i, part) in split.parts.enumerated() {
                    let last = i + 1 == nparts
                    let ptext = getText(part)
                    let plen = ptext.len
                    slen += plen
                    let pmlen = moraLength(ptext)
                    smlen += pmlen
                    var tpart: Word = part
                    if last && slen > text.len, let sp = part as? SimpleText {
                        let newLen = max(1, plen + (text.len - slen))
                        tpart = ProxyText(source: sp, text: ptext.sub(0, newLen), kana: "")
                    }
                    total += calcScore(tpart, final: final && last,
                                       useLength: (last && useLength != nil) ? pmlen + (useLength! - smlen) : nil,
                                       scoreMod: last ? scoreMod : .int(0)).score
                }
                score = split.score + total
            }
        }

        var info = SegInfo()
        info.posi = posi
        info.seqSet = seqSet
        info.conj = conjData
        info.common = commonP ? commonOf : nil
        info.kpcl = (kanjiP || katakanaP, primaryP, commonP, longP)
        if let kanjiBreak {
            score = kanjiBreakPenalty(kanjiBreak, score, info: info, text: text, useLength: useLength, scoreMod: scoreMod)
        }
        return (score, info)
    }

    @discardableResult
    func genScore(_ segment: Segment, final: Bool = false, kanjiBreak: [Int]? = nil) -> Segment {
        let (score, info) = calcScore(segment.word, final: final, kanjiBreak: kanjiBreak)
        segment.score = score
        segment.info = info ?? SegInfo()
        return segment
    }

    func cullSegments(_ segments: [Segment]) -> [Segment] {
        guard !segments.isEmpty else { return [] }
        var segs = lispStableSort(segments) { compareCommon($0.info.common, $1.info.common) }
        segs = lispStableSort(segs) { $0.score > $1.score }
        let maxScore = segs[0].score
        // *identical-word-score-cutoff* = 1/2
        return Array(segs.prefix { Double($0.score) >= Double(maxScore) * 0.5 })
    }
}
