import Foundation
import Compression

/// Lê as abas de um .xlsx (ZIP com XML) e devolve as mesmas linhas usadas pelo leitor de .xls.
enum OOXMLReader {
    private static let maxEntrySize = 50 * 1024 * 1024

    static func sheets(fromZip bytes: [UInt8]) throws -> [SheetRows] {
        let files = try unzip(bytes)
        var strings: [String] = []
        if let shared = files["xl/sharedStrings.xml"] {
            let collector = SharedStringsCollector()
            let parser = XMLParser(data: Data(shared))
            parser.delegate = collector
            guard parser.parse() else { throw XLSError.corrupted("sharedStrings") }
            strings = collector.strings
        }

        let names = files.keys
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
            .sorted()
        guard !names.isEmpty else { throw XLSError.noWorkbook }

        return try names.map { name in
            guard let data = files[name] else { throw XLSError.noWorkbook }
            let collector = SheetCollector(strings: strings)
            let parser = XMLParser(data: Data(data))
            parser.delegate = collector
            guard parser.parse() else { throw XLSError.corrupted("planilha") }
            return collector.rows
        }
    }

    private static func unzip(_ bytes: [UInt8]) throws -> [String: [UInt8]] {
        guard bytes.count >= 22 else { throw XLSError.notXLS }
        var end = bytes.count - 22
        while end >= 0 {
            if try bytes.u32(end) == 0x0605_4B50 { break }
            end -= 1
        }
        guard end >= 0 else { throw XLSError.corrupted("ZIP") }

        let count = try bytes.u16(end + 10)
        var position = Int(try bytes.u32(end + 16))
        var result: [String: [UInt8]] = [:]

        for _ in 0..<count {
            guard try bytes.u32(position) == 0x0201_4B50 else { throw XLSError.corrupted("ZIP") }
            let method = try bytes.u16(position + 10)
            let compressed = Int(try bytes.u32(position + 20))
            let size = Int(try bytes.u32(position + 24))
            let nameLength = try bytes.u16(position + 28)
            let extraLength = try bytes.u16(position + 30)
            let commentLength = try bytes.u16(position + 32)
            let localOffset = Int(try bytes.u32(position + 42))
            guard position + 46 + nameLength <= bytes.count else { throw XLSError.corrupted("ZIP") }
            let name = String(bytes: bytes[(position + 46)..<(position + 46 + nameLength)], encoding: .utf8) ?? ""
            position += 46 + nameLength + extraLength + commentLength

            guard name.hasSuffix(".xml"), size <= maxEntrySize else { continue }
            let start = localOffset + 30 + (try bytes.u16(localOffset + 26)) + (try bytes.u16(localOffset + 28))
            guard start >= 0, start + compressed <= bytes.count else { throw XLSError.corrupted("ZIP") }
            let source = Array(bytes[start..<(start + compressed)])

            switch method {
            case 0:
                result[name] = source
            case 8:
                result[name] = try inflate(source, size: size)
            default:
                throw XLSError.corrupted("compressão")
            }
        }
        return result
    }

    private static func inflate(_ source: [UInt8], size: Int) throws -> [UInt8] {
        guard size > 0, !source.isEmpty else { return [] }
        var output = [UInt8](repeating: 0, count: size)
        let written = output.withUnsafeMutableBufferPointer { destination in
            source.withUnsafeBufferPointer { input in
                compression_decode_buffer(
                    destination.baseAddress!,
                    size,
                    input.baseAddress!,
                    input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw XLSError.corrupted("ZIP") }
        return output
    }

    private final class SharedStringsCollector: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var insideText = false
        private var phoneticDepth = 0

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "si": current = ""
            case "rPh": phoneticDepth += 1
            case "t": insideText = phoneticDepth == 0
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if insideText { current += string }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            switch elementName {
            case "si": strings.append(current)
            case "rPh": phoneticDepth -= 1
            case "t": insideText = false
            default: break
            }
        }
    }

    private final class SheetCollector: NSObject, XMLParserDelegate {
        var rows: SheetRows = [:]
        private let strings: [String]
        private var reference = ""
        private var type = ""
        private var value = ""
        private var capturing = false

        init(strings: [String]) {
            self.strings = strings
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "c":
                reference = attributeDict["r"] ?? ""
                type = attributeDict["t"] ?? "n"
                value = ""
            case "v", "t":
                capturing = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturing { value += string }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            switch elementName {
            case "v", "t":
                capturing = false
            case "c":
                guard !value.isEmpty, let position = Self.position(reference) else { return }
                switch type {
                case "s":
                    if let index = Int(value), index < strings.count {
                        rows[position.row, default: [:]][position.column] = .text(strings[index])
                    }
                case "str", "inlineStr":
                    rows[position.row, default: [:]][position.column] = .text(value)
                case "n":
                    if let number = Double(value) {
                        rows[position.row, default: [:]][position.column] = .number(number)
                    }
                default:
                    break
                }
            default:
                break
            }
        }

        /// "B12" vira coluna 1, linha 11.
        private static func position(_ reference: String) -> (row: Int, column: Int)? {
            var column = 0
            var row = 0
            for scalar in reference.unicodeScalars {
                if scalar.value >= 65, scalar.value <= 90 {
                    column = column * 26 + Int(scalar.value) - 64
                } else if scalar.value >= 48, scalar.value <= 57 {
                    row = row * 10 + Int(scalar.value) - 48
                } else {
                    return nil
                }
            }
            guard column > 0, row > 0 else { return nil }
            return (row - 1, column - 1)
        }
    }
}
