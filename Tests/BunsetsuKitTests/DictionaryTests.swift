@testable import BunsetsuKit
import Foundation
import Testing

/// Port of ichiran's tests.lisp. Needs a database built with `bunsetsu build`;
/// set BUNSETSU_DB to its path, otherwise the tests are skipped.
struct DictionaryTests {
    static let ichiran: Ichiran? = {
        guard let path = ProcessInfo.processInfo.environment["BUNSETSU_DB"] else { return nil }
        return try? Ichiran(databasePath: path)
    }()

    func ich() throws -> Ichiran {
        guard let i = DictionaryTests.ichiran else { throw SkipError() }
        return i
    }

    func segment(_ ich: Ichiran, _ str: String) -> [String?] {
        ich.simpleSegment(text: str).map { $0.type == .gap ? nil : $0.text }
    }

    @Test(.enabled(if: DictionaryTests.ichiran != nil, "set BUNSETSU_DB")) func testSegmentation() throws {
        let ich = try ich()
        let url = Bundle.module.url(forResource: "segmentation", withExtension: "json", subdirectory: "Resources")!
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[Any]]
        var failures: [String] = []
        for c in cases {
            let str = c[0] as! String
            let expected = (c[1] as! [Any]).map { $0 as? String }
            let got = segment(ich, str)
            if got != expected {
                failures.append("\(str): expected \(expected.map { $0 ?? "<gap>" }) got \(got.map { $0 ?? "<gap>" })")
            }
        }
        for f in failures { print("SEGMENTATION FAILURE " + f) }
        let unexpected = failures.filter { f in !DictionaryTests.jmdictDrift.contains { f.hasPrefix($0 + ":") } }
        #expect(unexpected.isEmpty, "\(unexpected.count)/\(cases.count) segmentation failures")
    }

    /// Cases whose expected segmentation in ichiran's tests predates newer JMdict entries
    /// (e.g. かと 2871200, ですけど 2871534, といい 2872982, き 2872080).
    static let jmdictDrift: Set<String> = [
        "みんな土足でおいで", "戻りたいかと言われる", "昨日といいどうしてこう", "いっぱいきそう",
        "期待されがちなので男女", "出したいときは", "どなた様でございましょうか", "要素はないかと",
        "芝居もどきのせりふを言う", "気を遣ってくれてるのかと思ってました", "器用なのですぐ上達しますよ",
        "上手く案内出来てたらいいんですけど",
    ]

    @Test(.enabled(if: DictionaryTests.ichiran != nil, "set BUNSETSU_DB")) func testWordInfoJSON() throws {
        let ich = try ich()
        for word in ["の", "赤かったろう", "書いてきてる", "捩じり鉢巻きで", "夕べ", "さくや", "建ち並ばなきゃ", "建ち並びましてる",
                     "どおりで", "十万三", "5万100", "1234", "1日", "2期", "三羽", "1万500円", "オレら", "一本取られた", "一本とられた"] {
            let wi = ich.synchronized { ich.wordInfoFromText(word) }
            #expect(ich.glossJSON(wi).serialized().count > 2, "\(word)")
        }
    }

    @Test(.enabled(if: DictionaryTests.ichiran != nil, "set BUNSETSU_DB")) func testCounters() throws {
        let ich = try ich()
        let counters = ["倍", "晩", "秒", "着", "挺", "丁", "台", "段", "度", "円", "服", "幅", "分", "杯", "発", "遍", "篇", "匹", "本",
                        "時", "畳", "帖", "条", "課", "日", "回", "ヵ月", "階", "軒", "機", "個", "脚", "間", "枚", "巻", "名", "年", "人",
                        "列", "輪", "輌", "才", "歳", "棹", "冊", "隻", "章", "首", "足", "艘", "反", "滴", "点", "頭", "つ", "通", "対",
                        "羽", "把", "割", "膳", "時間", "週間", "人中", "番目", "期目", "巻目"]
        var failures: [String] = []
        for ctr in counters {
            for n in ["1", "三", "十一"] where !(ctr == "つ" && n == "十一") {
                let s = n + ctr
                let got = segment(ich, s)
                if got != [s] { failures.append("\(s): \(got)") }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    @Test(.enabled(if: DictionaryTests.ichiran != nil, "set BUNSETSU_DB")) func testMatchReadings() throws {
        let ich = try ich()
        func k(_ kanji: String, _ r: String, _ t: String, _ rendaku: Bool = false, _ gem: String? = nil) -> ReadingMatch {
            .kanji(kanji: kanji, reading: r, type: t, rendaku: rendaku, geminated: gem)
        }
        #expect(ich.matchKanjiReadings("取次店", "とりつぎてん") == [k("取", "とり", "ja_kun"), k("次", "つぎ", "ja_kun"), k("店", "てん", "ja_on")])
        #expect(ich.matchKanjiReadings("助っ人", "すけっと") == [k("助", "すけ", "ja_kun"), .kana("っ"), k("人", "と", "ja_kun")])
        #expect(ich.matchKanjiReadings("頑張って", "がんばって") == [k("頑", "がん", "ja_on"), k("張", "ば", "ja_kun"), .kana("って")])
        #expect(ich.matchKanjiReadings("肝心", "かんじん") == [k("肝", "かん", "ja_on"), k("心", "じん", "ja_on", true)])
        #expect(ich.matchKanjiReadings("決心", "けっしん") == [k("決", "けっ", "ja_on", false, "つ"), k("心", "しん", "ja_on")])
        #expect(ich.matchKanjiReadings("行方", "ゆくえ") == [k("行", "ゆ", "ja_kun"), k("方", "くえ", "irr")])
        #expect(ich.matchKanjiReadings("時計", "とけい") == [k("時", "と", "irr"), k("計", "けい", "ja_on")])
        #expect(ich.matchKanjiReadings("北方", "ほっぽう") == [k("北", "ほっ", "ja_on", false, "く"), k("方", "ぽう", "ja_on", true)])
        #expect(ich.matchKanjiReadings("明後日", "あさって") == [k("明", "あ", "ja_kun"), k("後", "さっ", "irr"), k("日", "て", "irr")])
    }

    @Test(.enabled(if: DictionaryTests.ichiran != nil, "set BUNSETSU_DB")) func testDeIsConjugationOfDa() throws {
        let ich = try ich()
        #expect(ich.synchronized { ich.selectConjs(2028980, .none).first?.from } == 2089020)
    }

    @Test(.enabled(if: DictionaryTests.ichiran != nil, "set BUNSETSU_DB")) func testRomanize() throws {
        let ich = try ich()
        #expect(ich.romanize("一覧は最高だぞ") == "ichiran wa saikō da zo")
    }
}

struct SkipError: Error {}
