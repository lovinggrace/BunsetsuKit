@testable import BunsetsuKit
import Foundation
import Testing

/// Compares a compact database (BUNSETSU_DB) with the full database it was built from (BUNSETSU_FULL_DB):
/// computing conjugations at lookup time must give the same results as storing them.
struct CompactDatabaseTests {
    static let full: Ichiran? = {
        guard let path = ProcessInfo.processInfo.environment["BUNSETSU_FULL_DB"] else { return nil }
        return try? Ichiran(databasePath: path)
    }()

    static var enabled: Bool { full != nil && DictionaryTests.ichiran?.virtualMode == true }

    func describe(_ ich: Ichiran, _ text: String) -> String {
        ich.segment(text, limit: 1).first.map { words, score in
            "\(score) " + words.map { "\($0.text)[\($0.kana.values.joined(separator: "/"))]\($0.score)" }.joined(separator: " ")
        } ?? ""
    }

    @Test(.enabled(if: CompactDatabaseTests.enabled, "set BUNSETSU_DB (compact) and BUNSETSU_FULL_DB"))
    func testSameSegmentation() throws {
        let compact = DictionaryTests.ichiran!, full = CompactDatabaseTests.full!
        let url = Bundle.module.url(forResource: "segmentation", withExtension: "json", subdirectory: "Resources")!
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[Any]]
        var diffs: [String] = []
        for c in cases {
            let text = c[0] as! String
            let a = describe(compact, text), b = describe(full, text)
            if a != b { diffs.append("\(text):\n  compact \(a)\n  full    \(b)") }
        }
        for d in diffs { print("COMPACT DIFF " + d) }
        #expect(diffs.isEmpty, "\(diffs.count)/\(cases.count) segmentations differ")
    }

    @Test(.enabled(if: CompactDatabaseTests.enabled, "set BUNSETSU_DB (compact) and BUNSETSU_FULL_DB"))
    func testSameGlosses() {
        let compact = DictionaryTests.ichiran!, full = CompactDatabaseTests.full!
        for text in ["食べさせられなかった", "書いてきてる", "見られたくない", "行かなければならない", "一覧は最高だぞ", "しませんか"] {
            let a = compact.romanizeWithInfo(text), b = full.romanizeWithInfo(text)
            #expect(a.text == b.text)
            #expect(a.info.map(\.1) == b.info.map(\.1), "\(text)")
        }
    }
}
