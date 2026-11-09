import Foundation

enum XLSError: LocalizedError {
    case notXLS
    case corrupted(String)
    case noWorkbook
    case unknownLayout
    case passwordRequired
    case wrongPassword
    case unsupportedEncryption

    var errorDescription: String? {
        switch self {
        case .notXLS: return "Este arquivo não é uma planilha do Excel."
        case .corrupted(let detail): return "A planilha parece corrompida (\(detail))."
        case .noWorkbook: return "Não encontrei a planilha dentro do arquivo."
        case .unknownLayout: return "Não reconheci este arquivo. Use o extrato de conta corrente (.xls) ou a fatura do cartão (.xlsx) do BTG."
        case .passwordRequired: return "Este arquivo precisa de senha."
        case .wrongPassword: return "Senha incorreta."
        case .unsupportedEncryption: return "Este arquivo usa um tipo de senha que o app ainda não abre."
        }
    }
}

extension Array where Element == UInt8 {
    func u16(_ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= count else { throw XLSError.corrupted("u16") }
        return Int(self[offset]) | Int(self[offset + 1]) << 8
    }

    func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw XLSError.corrupted("u32") }
        var value = UInt32(self[offset])
        value |= UInt32(self[offset + 1]) << 8
        value |= UInt32(self[offset + 2]) << 16
        value |= UInt32(self[offset + 3]) << 24
        return value
    }

    func u64(_ offset: Int) throws -> UInt64 {
        let low = UInt64(try u32(offset))
        let high = UInt64(try u32(offset + 4))
        return low | high << 32
    }
}

/// Lê o contêiner OLE2/CFB usado por .xls e por arquivos Office com senha.
struct CompoundFile {
    private static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let lastRegular: UInt32 = 0xFFFF_FFFA

    private let bytes: [UInt8]
    private let sectorSize: Int
    private let miniSize: Int
    private let miniCutoff: Int
    private let fat: [UInt32]
    private let miniFat: [UInt8]
    private let miniStream: [UInt8]
    private let entries: [String: (start: UInt32, size: Int)]

    static func isCompoundFile(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 512 && Array(bytes[0..<8]) == signature
    }

    init(bytes: [UInt8]) throws {
        guard Self.isCompoundFile(bytes) else { throw XLSError.notXLS }

        let sectorSize = 1 << (try bytes.u16(0x1E))
        let miniSize = 1 << (try bytes.u16(0x20))
        guard sectorSize == 512 || sectorSize == 4096 else { throw XLSError.corrupted("setor") }

        let fatSectors = Int(try bytes.u32(0x2C))
        let directoryStart = try bytes.u32(0x30)
        let miniCutoff = Int(try bytes.u32(0x38))
        let miniFatStart = try bytes.u32(0x3C)
        let difatStart = try bytes.u32(0x44)
        var difatCount = Int(try bytes.u32(0x48))
        let perSector = sectorSize / 4

        var fatList: [UInt32] = []
        for i in 0..<109 { fatList.append(try bytes.u32(0x4C + 4 * i)) }
        var nextDifat = difatStart
        while difatCount > 0, nextDifat < Self.lastRegular {
            let base = (Int(nextDifat) + 1) * sectorSize
            for i in 0..<(perSector - 1) { fatList.append(try bytes.u32(base + 4 * i)) }
            nextDifat = try bytes.u32(base + sectorSize - 4)
            difatCount -= 1
        }

        var fat: [UInt32] = []
        fat.reserveCapacity(fatSectors * perSector)
        for sector in fatList.prefix(fatSectors) where sector < Self.lastRegular {
            let base = (Int(sector) + 1) * sectorSize
            for i in 0..<perSector { fat.append(try bytes.u32(base + 4 * i)) }
        }

        let directory = try Self.chain(from: directoryStart, bytes: bytes, fat: fat, sectorSize: sectorSize)
        var rootStart: UInt32 = Self.lastRegular
        var found: [String: (start: UInt32, size: Int)] = [:]
        var position = 0
        while position + 128 <= directory.count {
            let nameLength = try directory.u16(position + 64)
            if nameLength >= 2, nameLength <= 64 {
                let nameBytes = directory[position..<(position + nameLength - 2)]
                let name = String(bytes: nameBytes, encoding: .utf16LittleEndian) ?? ""
                let start = try directory.u32(position + 116)
                let size = Int(truncatingIfNeeded: try directory.u64(position + 120) & 0xFFFF_FFFF)
                if directory[position + 66] == 5 { rootStart = start }
                if found[name] == nil { found[name] = (start, size) }
            }
            position += 128
        }

        self.bytes = bytes
        self.sectorSize = sectorSize
        self.miniSize = miniSize
        self.miniCutoff = miniCutoff
        self.fat = fat
        self.entries = found
        self.miniFat = try Self.chain(from: miniFatStart, bytes: bytes, fat: fat, sectorSize: sectorSize)
        self.miniStream = try Self.chain(from: rootStart, bytes: bytes, fat: fat, sectorSize: sectorSize)
    }

    func contains(_ name: String) -> Bool {
        entries[name] != nil
    }

    func read(_ name: String) throws -> [UInt8] {
        guard let stream = entries[name] else { throw XLSError.noWorkbook }

        if stream.size >= miniCutoff {
            let data = try Self.chain(from: stream.start, bytes: bytes, fat: fat, sectorSize: sectorSize)
            guard data.count >= stream.size else { throw XLSError.corrupted("stream curto") }
            return Array(data[0..<stream.size])
        }

        var out: [UInt8] = []
        var current = stream.start
        var steps = 0
        while current < Self.lastRegular, out.count < stream.size {
            let base = Int(current) * miniSize
            guard base + miniSize <= miniStream.count, steps * 4 <= miniFat.count else {
                throw XLSError.corrupted("miniFAT")
            }
            out.append(contentsOf: miniStream[base..<(base + miniSize)])
            current = try miniFat.u32(Int(current) * 4)
            steps += 1
        }
        guard out.count >= stream.size else { throw XLSError.corrupted("mini stream curto") }
        return Array(out[0..<stream.size])
    }

    private static func chain(from start: UInt32, bytes: [UInt8], fat: [UInt32], sectorSize: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        var current = start
        var steps = 0
        while current < lastRegular {
            guard Int(current) < fat.count, steps <= fat.count else { throw XLSError.corrupted("FAT") }
            let base = (Int(current) + 1) * sectorSize
            guard base + sectorSize <= bytes.count else { throw XLSError.corrupted("setor fora do arquivo") }
            out.append(contentsOf: bytes[base..<(base + sectorSize)])
            current = fat[Int(current)]
            steps += 1
        }
        return out
    }
}
