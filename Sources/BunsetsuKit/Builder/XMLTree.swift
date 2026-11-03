// Streaming XML reading for JMdict / kanjidic (replaces cxml/klacks)

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

final class XNode {
    let name: String
    let attributes: [String: String]
    var children: [XNode] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// `node-text`: all text below this element
    var nodeText: String {
        children.isEmpty ? text : text + children.map(\.nodeText).joined()
    }

    /// `get-elements-by-tag-name` (descendants in document order)
    func elements(_ tag: String) -> [XNode] {
        var result: [XNode] = []
        for c in children {
            if c.name == tag { result.append(c) }
            result += c.elements(tag)
        }
        return result
    }

    func first(_ tag: String) -> XNode? { elements(tag).first }
}

/// Calls `handler` for every element named `target`, with its subtree.
final class StreamingXMLReader: NSObject, XMLParserDelegate {
    let target: String
    let handler: (XNode) -> Void
    private var stack: [XNode] = []
    private(set) var error: Error?

    init(target: String, handler: @escaping (XNode) -> Void) {
        self.target = target
        self.handler = handler
    }

    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        if !parser.parse() {
            throw DatabaseError(message: "XML parse error: \(parser.parserError?.localizedDescription ?? "unknown") at line \(parser.lineNumber)")
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if stack.isEmpty && elementName != target { return }
        let el = XNode(name: elementName, attributes: attributeDict)
        stack.last?.children.append(el)
        stack.append(el)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let last = stack.last else { return }
        if last.children.isEmpty {
            last.text += string
        } else {
            // text after child elements: keep it as an anonymous child to preserve order
            let t = XNode(name: "#text", attributes: [:])
            t.text = string
            last.children.append(t)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let el = stack.popLast() else { return }
        if stack.isEmpty { handler(el) }
    }
}

/// Prepares JMdict XML: removes the DTD and replaces entity references by their names
/// (ichiran's `fix-entities`, so that e.g. &n; becomes "n").
func preprocessJMdict(_ data: Data) -> Data {
    guard var s = String(data: data, encoding: .utf8) else { return data }
    if let start = s.range(of: "<!DOCTYPE"), let end = s.range(of: "]>", range: start.upperBound..<s.endIndex) {
        s.removeSubrange(start.lowerBound..<end.upperBound)
    }
    let predefined: Set<String> = ["lt", "gt", "amp", "apos", "quot"]
    var out = String()
    out.reserveCapacity(s.utf8.count)
    var i = s.startIndex
    while let amp = s[i...].firstIndex(of: "&") {
        out += s[i..<amp]
        if let semi = s[amp...].prefix(64).firstIndex(of: ";") {
            let name = String(s[s.index(after: amp)..<semi])
            if !predefined.contains(name), !name.hasPrefix("#"), name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) {
                out += name
            } else {
                out += s[amp...semi]
            }
            i = s.index(after: semi)
        } else {
            out += "&"
            i = s.index(after: amp)
        }
    }
    out += s[i...]
    return Data(out.utf8)
}
