import Foundation

enum Cell {
    case text(String)
    case number(Double)
}

typealias SheetRows = [Int: [Int: Cell]]

/// Leitor mínimo de BIFF8: extrai células de texto e número da primeira aba.
enum BIFFReader {
    private enum Record {
        static let bof = 0x0809
        static let eof = 0x000A
        static let sst = 0x00FC
        static let continuation = 0x003C
        static let labelSST = 0x00FD
        static let number = 0x0203
        static let rk = 0x027E
        static let mulRK = 0x00BD
        static let label = 0x0204
    }

    static func firstSheet(from stream: [UInt8]) throws -> SheetRows {
        var records: [(type: Int, data: [UInt8])] = []
        var position = 0
        while position + 4 <= stream.count {
            let type = try stream.u16(position)
            let length = try stream.u16(position + 2)
            let start = position + 4
            guard start + length <= stream.count else { break }
            records.append((type, Array(stream[start..<(start + length)])))
            position = start + length
        }

        var strings: [String] = []
        var rows: SheetRows = [:]
        var inWorksheet = false
        var index = 0

        func set(_ row: Int, _ column: Int, _ cell: Cell) {
            rows[row, default: [:]][column] = cell
        }

        while index < records.count {
            let (type, data) = records[index]
            switch type {
            case Record.bof:
                inWorksheet = try data.u16(2) == 0x0010

            case Record.sst:
                var segments = [data]
                var next = index + 1
                while next < records.count, records[next].type == Record.continuation {
                    segments.append(records[next].data)
                    next += 1
                }
                strings = try parseSST(segments)
                index = next
                continue

            case Record.eof where inWorksheet:
                return rows

            case Record.labelSST where inWorksheet:
                let stringIndex = Int(try data.u32(6))
                guard stringIndex < strings.count else { throw XLSError.corrupted("SST") }
                set(try data.u16(0), try data.u16(2), .text(strings[stringIndex]))

            case Record.number where inWorksheet:
                let bits = try data.u64(6)
                set(try data.u16(0), try data.u16(2), .number(Double(bitPattern: bits)))

            case Record.rk where inWorksheet:
                set(try data.u16(0), try data.u16(2), .number(decodeRK(try data.u32(6))))

            case Record.mulRK where inWorksheet:
                let row = try data.u16(0)
                let first = try data.u16(2)
                let count = (data.count - 6) / 6
                for i in 0..<max(count, 0) {
                    set(row, first + i, .number(decodeRK(try data.u32(4 + 6 * i + 2))))
                }

            case Record.label where inWorksheet:
                let length = try data.u16(6)
                guard data.count >= 9 else { throw XLSError.corrupted("LABEL") }
                let wide = data[8] & 1 == 1
                let end = 9 + length * (wide ? 2 : 1)
                guard end <= data.count else { throw XLSError.corrupted("LABEL") }
                let text = String(bytes: data[9..<end], encoding: wide ? .utf16LittleEndian : .isoLatin1) ?? ""
                set(try data.u16(0), try data.u16(2), .text(text))

            default:
                break
            }
            index += 1
        }
        return rows
    }

    private static func decodeRK(_ raw: UInt32) -> Double {
        let value: Double
        if raw & 2 != 0 {
            value = Double(Int32(bitPattern: raw) >> 2)
        } else {
            value = Double(bitPattern: UInt64(raw & 0xFFFF_FFFC) << 32)
        }
        return raw & 1 != 0 ? value / 100 : value
    }

    /// Strings podem atravessar registros CONTINUE; cada continuação no meio
    /// dos caracteres começa com um byte que redefine a largura.
    private static func parseSST(_ segments: [[UInt8]]) throws -> [String] {
        var segment = 0
        var position = 8

        func advanceIfNeeded() throws {
            while position >= segments[segment].count {
                segment += 1
                position = 0
                guard segment < segments.count else { throw XLSError.corrupted("SST curto") }
            }
        }

        func byte() throws -> UInt8 {
            try advanceIfNeeded()
            let value = segments[segment][position]
            position += 1
            return value
        }

        func u16() throws -> Int {
            let low = Int(try byte())
            return low | Int(try byte()) << 8
        }

        func u32() throws -> Int {
            let low = try u16()
            return low | (try u16()) << 16
        }

        func skip(_ count: Int) throws {
            for _ in 0..<count { _ = try byte() }
        }

        let unique = Int(try segments[0].u32(4))
        var result: [String] = []
        result.reserveCapacity(unique)

        for _ in 0..<unique {
            let count = try u16()
            let flags = try byte()
            var wide = flags & 0x01 != 0
            let richRuns = try flags & 0x08 != 0 ? u16() : 0
            let extSize = try flags & 0x04 != 0 ? u32() : 0

            var text = ""
            var remaining = count
            while remaining > 0 {
                if position >= segments[segment].count {
                    segment += 1
                    guard segment < segments.count else { throw XLSError.corrupted("SST curto") }
                    wide = segments[segment][0] & 0x01 != 0
                    position = 1
                }
                let available = segments[segment].count - position
                let take = min(remaining, wide ? available / 2 : available)
                guard take > 0 else { throw XLSError.corrupted("SST") }
                let end = position + take * (wide ? 2 : 1)
                let slice = segments[segment][position..<end]
                text += String(bytes: slice, encoding: wide ? .utf16LittleEndian : .isoLatin1) ?? ""
                position = end
                remaining -= take
            }
            try skip(4 * richRuns)
            try skip(extSize)
            result.append(text)
        }
        return result
    }
}
