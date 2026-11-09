import Foundation

struct ParsedStatement {
    var holderName: String?
    var lancamentos: [Lancamento] = []
    var balances: [DailyBalance] = []
}

/// Interpreta o extrato de conta corrente do BTG exportado em .xls.
enum BTGStatementParser {
    static func parse(data: Data) throws -> ParsedStatement {
        let file = try CompoundFile(bytes: [UInt8](data))
        let stream = try file.read(file.contains("Workbook") ? "Workbook" : "Book")
        let rows = try BIFFReader.firstSheet(from: stream)
        return try parse(rows: rows)
    }

    static func parse(rows: SheetRows) throws -> ParsedStatement {
        var result = ParsedStatement()
        var columns: [String: Int]?
        var occurrences: [String: Int] = [:]

        for rowIndex in rows.keys.sorted() {
            guard let row = rows[rowIndex] else { continue }
            let cells = row.sorted { $0.key < $1.key }

            if columns == nil {
                if result.holderName == nil,
                   let position = cells.firstIndex(where: { text($0.value)?.folded == "cliente:" }),
                   position + 1 < cells.count {
                    result.holderName = text(cells[position + 1].value)
                }
                if cells.contains(where: { text($0.value)?.folded == "data e hora" }) {
                    var map: [String: Int] = [:]
                    for (column, cell) in cells {
                        if let title = text(cell)?.folded { map[title] = column }
                    }
                    columns = map
                }
                continue
            }

            guard let map = columns,
                  let dateColumn = map["data e hora"],
                  let descriptionColumn = map["descricao"],
                  let valueColumn = map["valor"],
                  let rawDate = row[dateColumn].flatMap(text),
                  isTimestamp(rawDate),
                  let cents = row[valueColumn].flatMap(amountInCents) else { continue }

            let description = row[descriptionColumn].flatMap(text) ?? ""
            let category = map["categoria"].flatMap { row[$0] }.flatMap(text)

            if category == nil, description.folded == "saldo diario" {
                let day = "\(rawDate.dropFirst(6).prefix(4))-\(rawDate.dropFirst(3).prefix(2))-\(rawDate.prefix(2))"
                result.balances.append(DailyBalance(dayKey: day, cents: cents))
                continue
            }

            let type = map["transacao"].flatMap { row[$0] }.flatMap(text) ?? ""
            let key = "\(rawDate)|\(type)|\(description)|\(cents)"
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1

            result.lancamentos.append(Lancamento(
                id: "\(key)|\(occurrence)",
                rawDate: rawDate,
                bankCategory: category ?? "",
                type: type,
                description: description,
                cents: cents
            ))
        }

        guard columns != nil else { throw XLSError.unknownLayout }
        return result
    }

    private static func text(_ cell: Cell) -> String? {
        if case .text(let value) = cell {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func amountInCents(_ cell: Cell) -> Int? {
        switch cell {
        case .number(let value):
            return Int((value * 100).rounded())
        case .text(let value):
            let cleaned = value
                .replacingOccurrences(of: "R$", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: ".")
            return Double(cleaned).map { Int(($0 * 100).rounded()) }
        }
    }

    /// dd/MM/yyyy HH:mm
    private static func isTimestamp(_ value: String) -> Bool {
        let chars = Array(value)
        guard chars.count == 16 else { return false }
        for (i, c) in chars.enumerated() {
            switch i {
            case 2, 5: if c != "/" { return false }
            case 10: if c != " " { return false }
            case 13: if c != ":" { return false }
            default: if !c.isNumber { return false }
            }
        }
        return true
    }
}
