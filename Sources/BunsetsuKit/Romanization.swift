// Port of the transliteration part of ichiran (romanize.lisp)

import Foundation

/// A node of the character class tree built by `process-modifiers`.
indirect enum CCNode {
    case char(Unicode.Scalar)
    case cls(CharClassName)
    /// modifier applied to the rest of the tree
    case mod(CharClassName, [CCNode])
}

func getCharacterClasses(_ word: String) -> [CharClassItem] {
    word.unicodeScalars.map(getCharClass)
}

/// Replaces iteration characters in a character class list.
func processIterationCharacters(_ list: [CharClassItem]) -> [CharClassItem] {
    var result: [CharClassItem] = []
    var prev: CharClassItem? = nil
    for cc in list {
        if cc == .cls("iter") {
            if let prev { result.append(prev) }
        } else if cc == .cls("iter-v") {
            if let prev {
                if case .cls(let p) = prev { result.append(.cls(voiceChar(p))) } else { result.append(prev) }
            }
        } else {
            result.append(cc)
            prev = cc
        }
    }
    return result
}

func processModifiers(_ list: ArraySlice<CharClassItem>) -> [CCNode] {
    var result: [CCNode] = []
    var idx = list.startIndex
    while idx < list.endIndex {
        let cc = list[idx]
        if cc == .cls("sokuon") {
            result.append(.mod("sokuon", processModifiers(list[(idx + 1)...])))
            break
        } else if case .cls(let name) = cc, Characters.modifierClassSet.contains(name) {
            let last = result.popLast()
            result.append(.mod(name, last.map { [$0] } ?? []))
        } else {
            switch cc {
            case .cls(let c): result.append(.cls(c))
            case .char(let c): result.append(.char(c))
            }
        }
        idx += 1
    }
    return result
}

func leftmostAtom(_ nodes: [CCNode]) -> CCNode? {
    guard let first = nodes.first else { return nil }
    switch first {
    case .mod(_, let rest): return leftmostAtom(rest)
    default: return first
    }
}

/// A romanization method (the Lisp class hierarchy is flattened into one configurable struct).
public struct RomanizationMethod: Sendable {
    public enum Kind: Sendable { case generic, hepburn, simplifiedHepburn, traditionalHepburn, modifiedHepburn, kunreiSiki }

    public let kind: Kind
    var kanaTable: [CharClassName: String]
    var simplifications: [(String, String)]

    init(kind: Kind, kanaTable: [CharClassName: String], simplifications: [(String, String)] = []) {
        self.kind = kind
        self.kanaTable = kanaTable
        self.simplifications = simplifications
    }

    var isHepburn: Bool { kind != .generic && kind != .kunreiSiki }

    public static let hepburnBasic = RomanizationMethod(kind: .hepburn, kanaTable: hepburnKanaTable)
    public static let hepburnSimple = RomanizationMethod(kind: .simplifiedHepburn, kanaTable: hepburnKanaTable,
                                                         simplifications: [("oo", "o"), ("ou", "o"), ("uu", "u")])
    public static let hepburnPassport = RomanizationMethod(kind: .simplifiedHepburn, kanaTable: hepburnKanaTable,
                                                           simplifications: [("oo", "oh"), ("ou", "oh"), ("uu", "u")])
    public static let hepburnTraditional = RomanizationMethod(kind: .traditionalHepburn, kanaTable: hepburnKanaTable,
                                                              simplifications: [("oo", "ō"), ("ou", "ō"), ("uu", "ū")])
    public static let hepburnModified: RomanizationMethod = {
        var table = hepburnKanaTable
        table["wo"] = "o"
        return RomanizationMethod(kind: .modifiedHepburn, kanaTable: table,
                                  simplifications: [("oo", "ō"), ("ou", "ō"), ("uu", "ū"), ("aa", "ā"), ("ee", "ē")])
    }()
    public static let kunreiSiki = RomanizationMethod(kind: .kunreiSiki, kanaTable: kunreiSikiKanaTable)

    public static let `default` = hepburnTraditional

    // MARK: transliteration

    func rBase(_ item: CharClassName) -> String {
        kanaTable[item] ?? item.lowercased()
    }

    func romanizeCore(_ tree: [CCNode]) -> String {
        var out = ""
        for item in tree {
            switch item {
            case .char(let c): out.unicodeScalars.append(c)
            case .cls(let c): out += rBase(c)
            case .mod(let m, let rest): out += rApply(m, rest)
            }
        }
        return out
    }

    func rApply(_ modifier: CharClassName, _ tree: [CCNode]) -> String {
        if isHepburn {
            switch modifier {
            case "sokuon":
                if case .cls("chi")? = leftmostAtom(tree) { return "t" + romanizeCore(tree) }
            case "+ya", "+yu", "+yo":
                let v = modifier.dropFirst(2) // "a", "u", "o"
                if case .cls(let first)? = tree.first {
                    switch first {
                    case "shi": return "sh" + v
                    case "chi": return "ch" + v
                    case "ji", "dji": return "j" + v
                    default: break
                    }
                }
            default: break
            }
        }
        // generic-romanization
        if modifier != "sokuon", modifier != "long-vowel", let yoon = kanaTable[modifier] {
            if case .cls(let first)? = tree.first {
                switch first {
                case "u": return "w" + yoon
                case "a", "i", "e", "o": return (kanaTable[first] ?? first) + yoon
                default: break
                }
            }
            let inner = romanizeCore(tree)
            return inner.sub(0, max(0, inner.len - 1)) + yoon
        }
        // base methods
        switch modifier {
        case "sokuon":
            let inner = romanizeCore(tree)
            guard let c = inner.firstScalar, c.value < 0x80 else { return inner }
            return String(c) + inner
        case "long-vowel":
            return romanizeCore(tree)
        default:
            return romanizeCore(tree) + modifier.lowercased()
        }
    }

    func rSimplify(_ str: String) -> String {
        switch kind {
        case .generic:
            return str
        case .hepburn:
            return removeNApostrophe(str)
        case .simplifiedHepburn, .modifiedHepburn:
            return simplifyNgrams(removeNApostrophe(str), simplifications)
        case .traditionalHepburn:
            var s = simplifyNgrams(removeNApostrophe(str), simplifications)
            s = s.replacingOccurrences(of: "n'([aiueoy])", with: "n-$1", options: .regularExpression)
            return s.replacingOccurrences(of: "n([mbp])", with: "m$1", options: .regularExpression)
        case .kunreiSiki:
            return simplifyNgrams(removeNApostrophe(str), [("oo", "ô"), ("ou", "ô"), ("uu", "û")])
        }
    }

    private func removeNApostrophe(_ s: String) -> String {
        // remove apostrophe after n if the next character isn't a vowel
        s.replacingOccurrences(of: "n'([^aiueoy]|$)", with: "n$1", options: .regularExpression)
    }

    /// Romanizes a character class list.
    func romanizeList(_ list: [CharClassItem]) -> String {
        let tree = processModifiers(processIterationCharacters(list)[...])
        return rSimplify(romanizeCore(tree))
    }

    func rSpecial(_ word: String) -> String? {
        switch word {
        case "っ": return "!"
        case "ー": return "~"
        default: return nil
        }
    }

    /// Romanizes a single word (kana).
    public func romanizeWord(_ word: String, originalSpelling: String? = nil, normalize doNormalize: Bool = true) -> String {
        let word = doNormalize ? normalize(word) : word
        if let special = rSpecial(originalSpelling ?? word) { return special }
        return romanizeList(getCharacterClasses(processHints(word)))
    }

    // MARK: tables

    static let hepburnKanaTable: [CharClassName: String] = [
        "a": "a", "i": "i", "u": "u", "e": "e", "o": "o",
        "ka": "ka", "ki": "ki", "ku": "ku", "ke": "ke", "ko": "ko",
        "sa": "sa", "shi": "shi", "su": "su", "se": "se", "so": "so",
        "ta": "ta", "chi": "chi", "tsu": "tsu", "te": "te", "to": "to",
        "na": "na", "ni": "ni", "nu": "nu", "ne": "ne", "no": "no",
        "ha": "ha", "hi": "hi", "fu": "fu", "he": "he", "ho": "ho",
        "ma": "ma", "mi": "mi", "mu": "mu", "me": "me", "mo": "mo",
        "ya": "ya", "yu": "yu", "yo": "yo",
        "ra": "ra", "ri": "ri", "ru": "ru", "re": "re", "ro": "ro",
        "wa": "wa", "wi": "wi", "we": "we", "wo": "wo",
        "n": "n'",
        "ga": "ga", "gi": "gi", "gu": "gu", "ge": "ge", "go": "go",
        "za": "za", "ji": "ji", "zu": "zu", "ze": "ze", "zo": "zo",
        "da": "da", "dji": "ji", "dzu": "zu", "de": "de", "do": "do",
        "ba": "ba", "bi": "bi", "bu": "bu", "be": "be", "bo": "bo",
        "pa": "pa", "pi": "pi", "pu": "pu", "pe": "pe", "po": "po",
        "+a": "a", "+i": "i", "+u": "u", "+e": "e", "+o": "o",
        "+ya": "ya", "+yu": "yu", "+yo": "yo",
        "vu": "vu", "+wa": "wa",
    ]

    static let kunreiSikiKanaTable: [CharClassName: String] = [
        "a": "a", "i": "i", "u": "u", "e": "e", "o": "o",
        "ka": "ka", "ki": "ki", "ku": "ku", "ke": "ke", "ko": "ko",
        "sa": "sa", "shi": "si", "su": "su", "se": "se", "so": "so",
        "ta": "ta", "chi": "ti", "tsu": "tu", "te": "te", "to": "to",
        "na": "na", "ni": "ni", "nu": "nu", "ne": "ne", "no": "no",
        "ha": "ha", "hi": "hi", "fu": "hu", "he": "he", "ho": "ho",
        "ma": "ma", "mi": "mi", "mu": "mu", "me": "me", "mo": "mo",
        "ya": "ya", "yu": "yu", "yo": "yo",
        "ra": "ra", "ri": "ri", "ru": "ru", "re": "re", "ro": "ro",
        "wa": "wa", "wi": "i", "we": "e", "wo": "o",
        "n": "n'",
        "ga": "ga", "gi": "gi", "gu": "gu", "ge": "ge", "go": "go",
        "za": "za", "ji": "zi", "zu": "zu", "ze": "ze", "zo": "zo",
        "da": "da", "dji": "zi", "dzu": "zu", "de": "de", "do": "do",
        "ba": "ba", "bi": "bi", "bu": "bu", "be": "be", "bo": "bo",
        "pa": "pa", "pi": "pi", "pu": "pu", "pe": "pe", "po": "po",
        "+a": "a", "+i": "i", "+u": "u", "+e": "e", "+o": "o",
        "+ya": "ya", "+yu": "yu", "+yo": "yo",
        "vu": "vu", "+wa": "wa",
    ]
}

/// Romanizes kana text without dictionary lookup.
public func romanizeKana(_ word: String, method: RomanizationMethod = .default) -> String {
    method.romanizeWord(word)
}

/// `romanize-word-geo`
public func romanizeWordGeo(_ input: String, method: RomanizationMethod = .hepburnSimple) -> String {
    lispCapitalize(method.romanizeWord(input, normalize: true))
}

/// Lisp `string-capitalize`: first letter of every alphanumeric run upper-cased, rest lower-cased.
func lispCapitalize(_ s: String) -> String {
    var out = ""
    var inWord = false
    for ch in s {
        if ch.isLetter || ch.isNumber {
            out += inWord ? ch.lowercased() : ch.uppercased()
            inWord = true
        } else {
            out.append(ch)
            inWord = false
        }
    }
    return out
}

/// Joins romanized parts, inserting a space between word parts.
func joinParts(_ parts: [String]) -> String {
    var out = ""
    var lastSpace = true
    for part in parts {
        if !part.isEmpty, !lastSpace, let c = part.firstScalar, c.properties.isAlphabetic || c.properties.numericType != nil {
            out += " "
        }
        out += part
        if let l = part.lastScalar { lastSpace = l.properties.isWhitespace }
    }
    return out
}
