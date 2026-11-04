@testable import BunsetsuKit
import Foundation
import Testing

/// `dictionaryForms(of:)` maps segmented words to JMdict `seq` numbers of their dictionary forms.
/// Needs BUNSETSU_DB (compact or full).
struct DictionaryFormsTests {
    func forms(_ ich: Ichiran, _ text: String) -> [String: [Int]] {
        Dictionary(ich.simpleSegment(text: text).map { ($0.text, ich.dictionaryForms(of: $0)) }, uniquingKeysWith: { a, _ in a })
    }

    @Test(.enabled(if: DictionaryTests.ichiran != nil, "set BUNSETSU_DB")) func testConjugatedForms() throws {
        let ich = DictionaryTests.ichiran!
        let words = forms(ich, "寿司を食べさせられなかった")
        #expect(words["寿司"] == [1595650])
        #expect(words["食べさせられなかった"] == [1358280]) // 食べる
    }

    @Test(.enabled(if: DictionaryTests.ichiran != nil, "set BUNSETSU_DB")) func testCompoundsListMainWordFirst() throws {
        let ich = DictionaryTests.ichiran!
        let words = forms(ich, "子供が泣いていた")
        #expect(words["泣いていた"]?.first == 1229840) // 泣く, then いる
        #expect(words["泣いていた"]?.contains(1577980) == true)
    }
}
