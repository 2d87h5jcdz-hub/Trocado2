import Foundation

enum ImportedFile {
    case statement(ParsedStatement)
    case invoice(ParsedInvoice)
}

enum ImportRouter {
    static func read(data: Data, password: String?) throws -> ImportedFile {
        let bytes = [UInt8](data)

        if bytes.starts(with: [0x50, 0x4B]) {
            return .invoice(try BTGInvoiceParser.parse(sheets: OOXMLReader.sheets(fromZip: bytes)))
        }

        if CompoundFile.isCompoundFile(bytes) {
            let file = try CompoundFile(bytes: bytes)
            if file.contains("EncryptedPackage") {
                guard let password else { throw XLSError.passwordRequired }
                let zip = try OfficeDecryptor.decrypt(file, password: password)
                return .invoice(try BTGInvoiceParser.parse(sheets: OOXMLReader.sheets(fromZip: zip)))
            }
            return .statement(try BTGStatementParser.parse(data: data))
        }

        throw XLSError.notXLS
    }
}
