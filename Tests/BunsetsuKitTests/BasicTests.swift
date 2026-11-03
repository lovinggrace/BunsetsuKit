@testable import BunsetsuKit
import Foundation
import Testing

/// Tests that don't need a dictionary database.
struct BasicTests {
    @Test func testParseNumber() throws {
        for n in [0, 10001, 20020001, 12423000430] {
            #expect(try Numbers.parseNumber(Numbers.numberToKanji(n)) == n)
        }
        #expect(try Numbers.parseNumber("100万") == 1000000)
        #expect(try Numbers.parseNumber("100万500") == 1000500)
    }

    @Test func testNumberToKana() {
        #expect(Numbers.numberToKana(300, separator: "") == "さんびゃく")
        #expect(Numbers.numberToKana(8000, separator: "") == "はっせん")
        #expect(Numbers.numberToKanji(2024) == "二千二十四")
    }

    @Test func testNumberSplit() {
        let s = basicSplit("二〇二〇")
        #expect(s.count == 1)
        #expect(s[0].0 == .word)
        #expect(s[0].1 == "二〇二〇")
    }

    @Test func testBasicSplit() {
        let s = basicSplit("Hello, 世界! 123円")
        #expect(s.map(\.1) == ["Hello, ", "世界", "! ", "123円"])
        #expect(s.map(\.0) == [.misc, .word, .misc, .word])
    }

    @Test func testRomanizeKana() {
        #expect(romanizeKana("ちょっと") == "chotto")
        #expect(romanizeKana("とうきょう") == "tōkyō")
        #expect(romanizeKana("しんぶん") == "shimbun")
        #expect(romanizeKana("きんえん") == "kin-en")
        #expect(romanizeKana("ファイル") == "fairu")
        #expect(romanizeKana("とうきょう", method: .hepburnSimple) == "tokyo")
        #expect(romanizeKana("しんぶん", method: .kunreiSiki) == "sinbun")
        #expect(romanizeKana("ラーメン") == "ramen")
    }

    @Test func testKanaConversion() {
        #expect(asHiragana("カタカナ") == "かたかな")
        #expect(asKatakana("ひらがな") == "ヒラガナ")
        #expect(normalize("ｶﾞｷﾞ") == "ガギ")
    }

    @Test func testDeromanize() {
        #expect(romajiToKana("toukyou")?.canonical == "とうきょう")
        #expect(romajiToKana("kitte")?.canonical == "きって")
    }

    @Test func testMatchDiff() {
        let r = matchDiff("見る", "観る")
        #expect(r?.parts == [.diff("見", "観"), .same("る")])
    }
}
