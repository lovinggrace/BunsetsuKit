// Port of the segmentation part of dict.lisp

import Foundation

enum CounterOption {
    case none
    case auto
    case at(Int)
}

extension Ichiran {
    /// `find-word-full`
    func findWordFull(_ word: String, asHiragana: Bool = false, counter: CounterOption = .none) -> [Word] {
        let simpleWords = findWord(word)
        var result: [Word] = simpleWords
        result += findWordSuffix(word, matches: simpleWords)
        if asHiragana {
            result += findWordAsHiragana(word, exclude: simpleWords.map(\.seq))
        }
        switch counter {
        case .none: break
        case .auto:
            if let (s, e) = consecutiveCharGroups(.number, word).first {
                result += findCounter(word.sub(s, e), word.sub(e))
            }
        case .at(let d):
            result += findCounter(word.sub(0, d), word.sub(d), unique: simpleWords.isEmpty)
        }
        return result
    }

    /// words cannot start or end after sokuon and before yoon characters
    func findStickyPositions(_ str: String) -> Set<Int> {
        let s = str.scalars
        var result = Set<Int>()
        for pos in 0..<s.count {
            let cc = charClassName(s[pos])
            if cc == "sokuon" {
                if pos != s.count - 1, let next = charClassName(s[pos + 1]), Characters.kanaClassSet.contains(next) {
                    result.insert(pos + 1)
                }
            } else if let cc, Characters.modifierClassSet.contains(cc) || Characters.iterationClassSet.contains(cc) {
                let lastAndLong = pos == s.count - 1
                    && (cc == "long-vowel" || (pos > 0 && longVowelModifierP(cc, s[pos - 1])))
                if !lastAndLong { result.insert(pos) }
            }
        }
        return result
    }

    func joinSubstringWordsStar(_ str: String) -> (result: [(Int, Int, [Segment])], kanjiBreak: [Int]) {
        let s = str.scalars
        let sticky = findStickyPositions(str)
        let savedHash = substringHash, savedMap = suffixMapTemp, savedEnd = suffixNextEnd
        defer { substringHash = savedHash; suffixMapTemp = savedMap; suffixNextEnd = savedEnd }
        let hash = findSubstringWords(str, sticky: sticky)
        let katakanaGroups = Dictionary(consecutiveCharGroups(.katakana, str), uniquingKeysWith: { a, _ in a })
        let numberGroups = Dictionary(consecutiveCharGroups(.number, str), uniquingKeysWith: { a, _ in a })
        let suffixMap = getSuffixMap(str)
        var kanjiBreak: [Int] = []
        var ends = Set<Int>()
        var result: [(Int, Int, [Segment])] = []
        for start in 0..<s.count where !sticky.contains(start) {
            let katakanaGroupEnd = katakanaGroups[start]
            let numberGroupEnd = numberGroups[start]
            var end = start + 1
            while end <= min(s.count, start + Ichiran.maxWordLength) {
                defer { end += 1 }
                if sticky.contains(end) { continue }
                let part = String(scalars: s[start..<end])
                suffixMapTemp = suffixMap
                suffixNextEnd = end
                substringHash = hash
                var counter = CounterOption.none
                if let nge = numberGroupEnd, nge <= end, nge - start <= 20 { counter = .at(nge - start) }
                let words = findWordFull(part, asHiragana: katakanaGroupEnd == end, counter: counter)
                let segments = words.map { Segment(start: start, end: end, word: $0) }
                if !segments.isEmpty {
                    if start == 0 || ends.contains(start) {
                        let kb: [Int]
                        if Errata.forceKanjiBreak.contains(part) {
                            kb = Array((start + 1)..<(start + part.len))
                        } else if Errata.noKanjiBreak.contains(part) {
                            kb = []
                        } else {
                            kb = sequentialKanjiPositions(part, offset: start)
                        }
                        kanjiBreak = kb + kanjiBreak
                    }
                    ends.insert(end)
                    result.append((start, end, segments))
                }
            }
        }
        var seen = Set<Int>()
        return (result, kanjiBreak.filter { seen.insert($0).inserted })
    }

    /// `join-substring-words`
    func joinSubstringWords(_ str: String) -> [SegmentList] {
        let (result, kanjiBreak) = joinSubstringWordsStar(str)
        let kbSet = Set(kanjiBreak)
        let len = str.len
        let endsWithLw = str.endsWith("ー")
        var lists: [SegmentList] = []
        for (start, end, segments) in result {
            let kb = [start, end].filter(kbSet.contains).map { $0 - start }
            var sl: [Segment] = []
            for seg in segments {
                genScore(seg, final: seg.end == len || (endsWithLw && seg.end == len - 1), kanjiBreak: kb.isEmpty ? nil : kb)
                if seg.score >= scoreCutoff { sl.append(seg) }
            }
            if !sl.isEmpty {
                lists.append(SegmentList(segments: cullSegments(sl), start: start, end: end, matches: segments.count))
            }
        }
        return lists
    }

    func getSegInitial(_ seg: SegmentList) -> [SegmentList] {
        applySegfilters(nil, seg).map(\.right)
    }

    func getSegSplits(_ left: SegmentList, _ right: SegmentList) -> [[PathItem]] {
        applySegfilters(left, right).flatMap { pair -> [[PathItem]] in
            guard let l = pair.left else { return [] }
            return [getPenalties(l, pair.right)] + getSynergies(l, pair.right)
        }
    }

    func expandSegmentList(_ sl: SegmentList) {
        var segs: [Segment] = []
        for seg in sl.segments {
            segs.append(seg)
            if let split = getSegsplit(seg) {
                segs.append(split)
                sl.matches += 1
            }
        }
        sl.segments = lispStableSort(segs) { $0.score > $1.score }
    }

    /// `find-best-path`: payloads are stored most recent item first, as in Lisp
    func findBestPath(_ segmentLists: [SegmentList], _ strLength: Int, limit: Int = 5) -> [(path: [PathItem], score: Int)] {
        let top = TopArray<[PathItem]>(limit: limit)
        top.register(gapPenalty(0, strLength), [])
        for sl in segmentLists {
            expandSegmentList(sl)
            sl.top = TopArray(limit: limit)
        }
        // assume segments are sorted by (start, end) (as is the result of join-substring-words)
        for (i, seg1) in segmentLists.enumerated() {
            let gapLeft = gapPenalty(0, seg1.start)
            let gapRight = gapPenalty(seg1.end, strLength)
            for seg in getSegInitial(seg1) {
                let score1 = seg.score
                seg1.top!.register(gapLeft + score1, [.list(seg)])
                top.register(gapLeft + score1 + gapRight, [.list(seg)])
            }
            for seg2 in segmentLists[(i + 1)...] {
                let score2 = seg2.score
                guard seg2.start >= seg1.end else { continue }
                let gapLeft = gapPenalty(seg1.end, seg2.start)
                let gapRight = gapPenalty(seg2.end, strLength)
                for tai in seg1.top!.items {
                    guard let first = tai.payload.first, case .list(let segLeft) = first else { continue }
                    let tail = Array(tai.payload.dropFirst())
                    let score3 = segLeft.score
                    let scoreTail = tai.score - score3
                    for split in getSegSplits(segLeft, seg2) {
                        let accum = gapLeft + max(split.reduce(0) { $0 + $1.score }, score3 + 1, score2 + 1) + scoreTail
                        let path = split + tail
                        seg2.top!.register(accum, path)
                        top.register(accum + gapRight, path)
                    }
                }
            }
        }
        for sl in segmentLists { sl.top = nil }
        return top.items.map { (Array($0.payload.reversed()), $0.score) }
    }

    // MARK: word info

    func wordInfoFromSegment(_ segment: Segment) -> WordInfo {
        let word = segment.word
        let wi = WordInfo(type: wordType(word), text: getText(segment), kana: .single(getKana(word)))
        wi.seq = wordSeq(word)
        if let s = word as? SimpleText {
            wi.conjugations = s.conjugations
            wi.trueText = s.trueText
        }
        if let c = word as? CompoundText {
            let primarySeq = seqOf(c.primary)
            wi.components = c.words.map { w in
                let cwi = WordInfo(type: wordType(w), text: getText(w), kana: .single(getKana(w)))
                cwi.trueText = trueText(w)
                cwi.seq = wordSeq(w)
                cwi.conjugations = conjugations(w)
                cwi.primary = seqOf(w) == primarySeq
                return cwi
            }
        }
        if let c = word as? CounterText {
            wi.counter = (c.valueString(), c.ordinalp)
        }
        wi.score = segment.score
        wi.start = segment.start
        wi.end = segment.end
        return wi
    }

    /// *segment-score-cutoff* = 2/3
    func wordInfoFromSegmentList(_ sl: SegmentList) -> WordInfo {
        let all = sl.segments.map(wordInfoFromSegment)
        guard let wi1 = all.first else {
            return WordInfo(type: .gap, text: "", kana: .single(""))
        }
        let maxScore = wi1.score
        let list = all.filter { !(Double($0.score) < 2.0 / 3.0 * Double(maxScore)) }
        if list.count == 1 {
            wi1.skipped = sl.matches - 1
            return wi1
        }
        var kanaList: [String] = []
        for wi in list {
            for k in wi.kana.values where !kanaList.contains(k) { kanaList.append(k) }
        }
        let wi = WordInfo(type: wi1.type, text: wi1.text, kana: .multiple(kanaList))
        wi.seq = .list(list.map(\.seq))
        wi.components = list
        wi.alternative = true
        wi.score = wi1.score
        wi.start = sl.start
        wi.end = sl.end
        wi.skipped = sl.matches - list.count
        return wi
    }

    /// `word-info-from-text`
    func wordInfoFromText(_ text: String) -> WordInfo {
        let readings = findWordFull(text, counter: .auto)
        let segments = readings.map { genScore(Segment(start: 0, end: text.len, word: $0, text: text)) }
        return wordInfoFromSegmentList(SegmentList(segments: segments, start: 0, end: text.len, matches: segments.count))
    }

    func fillSegmentPath(_ str: String, _ path: [PathItem]) -> [WordInfo] {
        var idx = 0
        var result: [WordInfo] = []
        func gap(_ start: Int, _ end: Int) -> WordInfo {
            let substr = str.sub(start, end)
            let wi = WordInfo(type: .gap, text: substr, kana: .single(substr))
            wi.start = start
            wi.end = end
            return wi
        }
        for item in path {
            guard case .list(let sl) = item else { continue }
            if sl.start > idx { result.append(gap(idx, sl.start)) }
            result.append(wordInfoFromSegmentList(sl))
            idx = sl.end
        }
        if idx < str.len { result.append(gap(idx, str.len)) }
        return processWordInfo(result)
    }

    /// Process readings such as nani/nan (hardcoded so far)
    func processWordInfo(_ list: [WordInfo]) -> [WordInfo] {
        let nanClasses: Set<String> = ["ba", "bi", "bu", "be", "bo", "pa", "pi", "pu", "pe", "po",
                                       "da", "dji", "dzu", "de", "do", "za", "ji", "zu", "ze", "zo",
                                       "ta", "chi", "tsu", "te", "to", "na", "nu", "ne", "no",
                                       "ra", "ri", "ru", "re", "ro"]
        for (i, wi) in list.enumerated() where i + 1 < list.count && wi.text == "何" {
            var nani = false, nan = false
            for kana in list[i + 1].kana.values {
                guard let fc = kana.firstScalar else { continue }
                if let cls = charClassName(fc), nanClasses.contains(cls) { nan = true } else { nani = true }
            }
            if nan && nani { wi.kana = .single("なに") }
            else if nan { wi.kana = .single("なん") }
            else if nani { wi.kana = .single("なに") }
        }
        return list
    }

    /// `dict-segment`
    func dictSegment(_ str: String, limit: Int = 5) -> [(words: [WordInfo], score: Int)] {
        findBestPath(joinSubstringWords(str), str.len, limit: limit).map { (fillSegmentPath(str, $0.path), $0.score) }
    }

    func simpleSegment(_ str: String, limit: Int = 5) -> [WordInfo] {
        dictSegment(str, limit: limit).first?.words ?? []
    }

    /// `find-word-info`
    func findWordInfo(_ text: String, reading: String? = nil, rootOnly: Bool = false) -> [WordInfo] {
        let end = text.len
        let savedMap = suffixMapTemp, savedEnd = suffixNextEnd
        suffixMapTemp = getSuffixMap(text)
        suffixNextEnd = end
        defer { suffixMapTemp = savedMap; suffixNextEnd = savedEnd }
        let all: [Word] = rootOnly ? findWord(text, rootOnly: true)
            : findWordFull(text, asHiragana: testWord(text, .katakana), counter: .auto)
        let segments = lispStableSort(all.map { genScore(Segment(start: 0, end: end, word: $0, text: text)) }) { $0.score > $1.score }
        var wis = segments.map(wordInfoFromSegment)
        if let reading {
            wis = wis.compactMap { wi in
                if wi.kana == .single(reading) { return wi }
                if let seq = wi.seq.value,
                   !readingsOf(seq, .kana, text: reading).isEmpty {
                    wi.kana = .single(reading)
                    return wi
                }
                return nil
            }
        }
        return wis
    }
}
