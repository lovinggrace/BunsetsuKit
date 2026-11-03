// Command line interface (port of ichiran-cli, cli.lisp) plus database building.

import BunsetsuKit
import Foundation

let usage = """
Command line interface for BunsetsuKit (a Swift port of Ichiran)

Usage:
  bunsetsu [options] [input]
  bunsetsu build --jmdict JMdict_e --jmdictdb-data DIR [--kanjidic kanjidic2.xml] [--output bunsetsu.sqlite]

By default prints the romanization, other options change this behavior.

Options:
  -h, --help          print this help text
  -i, --with-info     print dictionary info
  -f, --full          full split info (as JSON)
  -w, --word          look up a single word (all readings with scores, as JSON)
  -l, --limit LIMIT   limit segmentations to the specified number (useful only with -f) [default: 1]
  -d, --db PATH       database path (default: $BUNSETSU_DB or ./bunsetsu.sqlite)
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())

if args.first == "build" {
    args.removeFirst()
    var opts: [String: String] = [:]
    var i = 0
    while i < args.count {
        guard args[i].hasPrefix("--"), i + 1 < args.count else { fail("fatal: invalid build arguments\n\n" + usage) }
        opts[String(args[i].dropFirst(2))] = args[i + 1]
        i += 2
    }
    guard let jmdict = opts["jmdict"], let data = opts["jmdictdb-data"] else { fail("fatal: --jmdict and --jmdictdb-data are required") }
    let output = opts["output"] ?? "bunsetsu.sqlite"
    do {
        let builder = try DictionaryBuilder(databasePath: output, jmdictDataDirectory: URL(fileURLWithPath: data))
        try builder.build(jmdict: URL(fileURLWithPath: jmdict), kanjidic: opts["kanjidic"].map { URL(fileURLWithPath: $0) })
    } catch {
        fail("ERROR: \(error)", code: 2)
    }
    exit(0)
}

var withInfo = false, full = false, lookup = false, limit = 1
var dbPath = ProcessInfo.processInfo.environment["BUNSETSU_DB"] ?? "bunsetsu.sqlite"
var free: [String] = []
var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "-i", "--with-info": withInfo = true
    case "-f", "--full": full = true
    case "-w", "--word": lookup = true
    case "-l", "--limit":
        guard i + 1 < args.count else { fail("fatal: option \"\(a)\" needs an argument!") }
        guard let l = Int(args[i + 1]) else { fail("fatal: cannot parse \"\(args[i + 1])\" as argument of \"\(a)\"") }
        limit = l
        i += 1
    case "-d", "--db":
        guard i + 1 < args.count else { fail("fatal: option \"\(a)\" needs an argument!") }
        dbPath = args[i + 1]
        i += 1
    default:
        if a.hasPrefix("-") && a.count > 1 {
            print("warning: \"\(a)\" option is unknown!")
        } else {
            free.append(a)
        }
    }
    i += 1
}

let input = free.joined(separator: " ")
let ichiran: Ichiran
do {
    ichiran = try Ichiran(databasePath: dbPath)
} catch {
    fail("ERROR: \(error)", code: 2)
}

if lookup {
    for wi in ichiran.lookup(input) { print(wi.score, ichiran.glossJSON(wi).serialized()) }
} else if full {
    print(ichiran.romanizeDetailed(input, limit: limit).serialized())
} else if withInfo {
    let (text, info) = ichiran.romanizeWithInfo(input)
    var out = text
    for (word, gloss) in info { out += "\n\n* \(word)  \(gloss)" }
    print(out)
} else {
    print(ichiran.romanize(input))
}
