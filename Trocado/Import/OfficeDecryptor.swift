import Foundation
import CryptoKit
import CommonCrypto

/// Abre arquivos .xlsx protegidos por senha (criptografia "Agile" do Office, versão 4.4).
enum OfficeDecryptor {
    private static let keyBlock: [UInt8] = [0x14, 0x6E, 0x0B, 0xE7, 0xAB, 0xAC, 0xD0, 0xD6]
    private static let verifierInputBlock: [UInt8] = [0xFE, 0xA7, 0xD2, 0x76, 0x3B, 0x4B, 0x9E, 0x79]
    private static let verifierHashBlock: [UInt8] = [0xD7, 0xAA, 0x0F, 0x6D, 0x30, 0x61, 0x34, 0x4E]
    private static let segmentSize = 4096

    static func decrypt(_ file: CompoundFile, password: String) throws -> [UInt8] {
        let info = try file.read("EncryptionInfo")
        guard try info.u16(0) == 4, try info.u16(2) == 4 else { throw XLSError.unsupportedEncryption }

        var xml = Array(info[8...])
        while xml.last == 0 { xml.removeLast() }
        let collector = AttributeCollector()
        let parser = XMLParser(data: Data(xml))
        parser.delegate = collector
        guard parser.parse(),
              let keyData = collector.keyData,
              let encryptedKey = collector.encryptedKey else { throw XLSError.unsupportedEncryption }

        guard keyData["cipherAlgorithm"] == "AES", encryptedKey["cipherAlgorithm"] == "AES",
              keyData["cipherChaining"] == "ChainingModeCBC", encryptedKey["cipherChaining"] == "ChainingModeCBC",
              let algorithm = encryptedKey["hashAlgorithm"],
              let spinCount = encryptedKey["spinCount"].flatMap({ Int($0) }),
              let keyBits = encryptedKey["keyBits"].flatMap({ Int($0) }),
              let blockSize = encryptedKey["blockSize"].flatMap({ Int($0) }),
              let salt = bytes(encryptedKey["saltValue"]),
              let encryptedValue = bytes(encryptedKey["encryptedKeyValue"]),
              let verifierInput = bytes(encryptedKey["encryptedVerifierHashInput"]),
              let verifierHash = bytes(encryptedKey["encryptedVerifierHashValue"]),
              let packageAlgorithm = keyData["hashAlgorithm"],
              let packageSalt = bytes(keyData["saltValue"]),
              let packageBlockSize = keyData["blockSize"].flatMap({ Int($0) }),
              spinCount > 0, keyBits > 0, blockSize == 16, packageBlockSize == 16 else {
            throw XLSError.unsupportedEncryption
        }

        var passwordBytes: [UInt8] = []
        for unit in password.utf16 {
            passwordBytes.append(UInt8(unit & 0xFF))
            passwordBytes.append(UInt8(unit >> 8))
        }

        var iterated = try digest(algorithm, salt + passwordBytes)
        for i in 0..<spinCount {
            iterated = try digest(algorithm, littleEndian(UInt32(i)) + iterated)
        }

        let keyLength = keyBits / 8
        func derive(_ block: [UInt8]) throws -> [UInt8] {
            let hashed = try digest(algorithm, iterated + block)
            if hashed.count >= keyLength { return Array(hashed[0..<keyLength]) }
            return hashed + [UInt8](repeating: 0x36, count: keyLength - hashed.count)
        }

        let iv = Array(salt.prefix(blockSize))
        let input = try aes(key: derive(verifierInputBlock), iv: iv, data: verifierInput)
        let expected = try aes(key: derive(verifierHashBlock), iv: iv, data: verifierHash)
        let actual = try digest(algorithm, Array(input.prefix(salt.count)))
        guard Array(expected.prefix(actual.count)) == actual else { throw XLSError.wrongPassword }

        let packageKey = Array(try aes(key: derive(keyBlock), iv: iv, data: encryptedValue).prefix(keyLength))

        let package = try file.read("EncryptedPackage")
        let plainSize = Int(truncatingIfNeeded: try package.u64(0))
        var output: [UInt8] = []
        output.reserveCapacity(package.count)
        var position = 8
        var segment: UInt32 = 0
        while position < package.count {
            let end = min(position + segmentSize, package.count)
            let usable = (end - position) - (end - position) % 16
            guard usable > 0 else { break }
            let segmentIV = Array(try digest(packageAlgorithm, packageSalt + littleEndian(segment)).prefix(16))
            output += try aes(key: packageKey, iv: segmentIV, data: Array(package[position..<(position + usable)]))
            position = end
            segment += 1
        }
        guard plainSize >= 0, plainSize <= output.count else { throw XLSError.corrupted("pacote") }
        return Array(output[0..<plainSize])
    }

    private static func bytes(_ base64: String?) -> [UInt8]? {
        guard let base64, let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        return [UInt8](data)
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private static func digest(_ algorithm: String, _ input: [UInt8]) throws -> [UInt8] {
        switch algorithm.uppercased().replacingOccurrences(of: "-", with: "") {
        case "SHA1": return Array(Insecure.SHA1.hash(data: input))
        case "SHA256": return Array(SHA256.hash(data: input))
        case "SHA384": return Array(SHA384.hash(data: input))
        case "SHA512": return Array(SHA512.hash(data: input))
        default: throw XLSError.unsupportedEncryption
        }
    }

    private static func aes(key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        let capacity = data.count
        var output = [UInt8](repeating: 0, count: capacity)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(0),
            key,
            key.count,
            iv,
            data,
            data.count,
            &output,
            capacity,
            &moved
        )
        guard status == CCCryptorStatus(kCCSuccess), moved == capacity else { throw XLSError.corrupted("AES") }
        return output
    }

    private final class AttributeCollector: NSObject, XMLParserDelegate {
        var keyData: [String: String]?
        var encryptedKey: [String: String]?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if elementName.hasSuffix("keyData") {
                keyData = attributeDict
            } else if elementName.hasSuffix("encryptedKey") {
                encryptedKey = attributeDict
            }
        }
    }
}
