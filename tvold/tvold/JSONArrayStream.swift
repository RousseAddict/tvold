import Foundation

// Streams a JSON file holding one top-level array of objects, handing back a
// single element at a time.
//
// NSJSONSerialization has no incremental mode on iOS 6, and the iptv-org
// catalogue is 20.7 MB across three files — channels.json alone is 10.1 MB.
// Parsing that in one call builds an object graph several times the file size,
// which is fatal on an A5 with roughly a 40 MB budget before jetsam.
//
// So: walk the file in fixed-size chunks, track brace/bracket depth to find
// each top-level element's byte range, and hand the platform parser one small
// object at a time. Peak memory is then governed by the largest single element
// (a few hundred bytes) rather than by the size of the file. Correctness for
// the awkward parts — escapes, \u sequences, number forms — still belongs to
// NSJSONSerialization; this only has to find the boundaries.
//
// Deliberately free of app dependencies so it can be compiled and verified
// standalone against the real files. See tools/json_stream_test.swift.
enum JSONArrayStream {

    enum Failure: Error {
        case cannotOpen
        case notAnArray
    }

    struct Stats {
        // Top-level elements whose boundaries were found.
        var elements = 0
        // Of those, the ones NSJSONSerialization accepted as an object.
        var parsed = 0
        var skipped: Int { return elements - parsed }
    }

    // Calls `body` once per element. A element that fails to parse is counted
    // and skipped rather than aborting the file: one malformed record upstream
    // should cost that record, not the whole refresh.
    @discardableResult
    static func forEachObject(inFileAt path: String,
                              chunkSize: Int = 64 * 1024,
                              body: ([String: Any]) -> Void) throws -> Stats {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw Failure.cannotOpen }
        defer { close(fd) }

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buf.deallocate() }

        // Bytes of the element currently being accumulated.
        var element = [UInt8]()
        element.reserveCapacity(4096)

        var stats = Stats()
        var sawArrayStart = false
        var depth = 0
        var inString = false
        var escaped = false

        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
        let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")

        while true {
            let n = read(fd, buf, chunkSize)
            if n <= 0 { break }

            var i = 0
            while i < n {
                let b = buf[i]
                i += 1

                if !sawArrayStart {
                    if b == openBracket { sawArrayStart = true; continue }
                    // Only whitespace may precede the array.
                    if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { continue }
                    throw Failure.notAnArray
                }

                // Everything from the opening brace onward belongs to the
                // element; the opening brace itself is added by its case below.
                if depth > 0 { element.append(b) }

                if inString {
                    if escaped { escaped = false }
                    else if b == backslash { escaped = true }
                    else if b == quote { inString = false }
                    continue
                }

                switch b {
                case quote:
                    inString = true
                case openBrace:
                    if depth == 0 {
                        element.removeAll(keepingCapacity: true)
                        element.append(b)
                    }
                    depth += 1
                case closeBrace:
                    guard depth > 0 else { break }
                    depth -= 1
                    if depth == 0 {
                        stats.elements += 1
                        // Drained per element, and this is not optional.
                        // NSJSONSerialization returns autoreleased Foundation
                        // objects; without a pool inside the loop the
                        // temporaries from every element in the file stay
                        // alive until the whole parse finishes, which measured
                        // at 42 MB peak on channels.json — streaming, but with
                        // none of the point of streaming.
                        autoreleasepool {
                            if let obj = (try? JSONSerialization.jsonObject(with: Data(element),
                                                                           options: []))
                                as? [String: Any] {
                                stats.parsed += 1
                                body(obj)
                            }
                        }
                        element.removeAll(keepingCapacity: true)
                    }
                case openBracket:
                    // Nested array inside an element. A bracket at depth 0 is
                    // the top-level array's own, already consumed above.
                    if depth > 0 { depth += 1 }
                case closeBracket:
                    if depth > 0 { depth -= 1 }
                default:
                    break
                }
            }
        }
        return stats
    }
}
