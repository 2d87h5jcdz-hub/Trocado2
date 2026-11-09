import Foundation

struct ParsedInvoice {
    let dueMonth: String
    let totalCents: Int
    let lancamentos: [Lancamento]
}

/// Interpreta a fatura do cartão BTG exportada em .xlsx.
enum BTGInvoiceParser {
    private static let months = [
        "janeiro": 1, "fevereiro": 2, "marco": 3, "abril": 4, "maio": 5, "junho": 6,
        "julho": 7, "agosto": 8, "setembro": 9, "outubro": 10, "novembro": 11, "dezembro": 12
    ]

    static func parse(sheets: [SheetRows]) throws -> ParsedInvoice {
        var dueMonth: String?
        var total: Int?
        var items: [Lancamento] = []
        var occurrences: [String: Int] = [:]

        for rows in sheets {
            var columns: [String: Int]?

            for rowIndex in rows.keys.sorted() {
                guard let row = rows[rowIndex] else { continue }
                let cells = row.sorted { $0.key < $1.key }.map(\.value)

                if dueMonth == nil, let title = value(after: "fatura cartao de credito", in: cells), case .text(let text) = title {
                    dueMonth = monthKey(text)
                }
                if total == nil, let found = value(after: "total da fatura", in: cells), case .number(let number) = found {
                    total = Int((number * 100).rounded())
                }

                let titles = row.compactMapValues { cell -> String? in
                    if case .text(let text) = cell { return text.folded }
                    return nil
                }
                if titles.values.contains("data"), titles.values.contains("descricao") {
                    if titles.values.contains("tipo de compra") {
                        var map: [String: Int] = [:]
                        for (column, title) in titles { map[title] = column }
                        columns = map
                    } else {
                        columns = nil
                    }
                    continue
                }

                guard let map = columns, let due = dueMonth,
                      let dateColumn = map["data"], let descriptionColumn = map["descricao"], let valueColumn = map["valor"],
                      let rawDate = row[dateColumn].flatMap(date),
                      case .text(let rawDescription)? = row[descriptionColumn],
                      case .number(let amount)? = row[valueColumn] else { continue }

                let description = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                var kind = ""
                if let column = map["tipo de compra"], case .text(let text)? = row[column] { kind = text }
                var authorization = ""
                if let column = map["codigo de autorizacao"], case .text(let text)? = row[column] { authorization = text }

                let cents = -Int((amount * 100).rounded())
                let key = "cartao|\(authorization)|\(rawDate)|\(description)|\(cents)"
                let occurrence = occurrences[key, default: 0]
                occurrences[key] = occurrence + 1

                items.append(Lancamento(
                    id: "\(key)|\(occurrence)",
                    rawDate: rawDate,
                    bankCategory: "",
                    type: kind,
                    description: description,
                    cents: cents,
                    billingMonth: due
                ))
            }
        }

        guard let foundMonth = dueMonth, let foundTotal = total else { throw XLSError.unknownLayout }
        return ParsedInvoice(dueMonth: foundMonth, totalCents: foundTotal, lancamentos: items)
    }

    private static func value(after label: String, in cells: [Cell]) -> Cell? {
        for (index, cell) in cells.enumerated() {
            if case .text(let text) = cell, text.folded == label, index + 1 < cells.count {
                return cells[index + 1]
            }
        }
        return nil
    }

    /// "Outubro/2026" vira "2026-10".
    private static func monthKey(_ text: String) -> String? {
        let parts = text.folded.split(separator: "/")
        guard parts.count == 2, let month = months[String(parts[0])], let year = Int(parts[1]) else { return nil }
        return String(format: "%04d-%02d", year, month)
    }

    /// Devolve dd/MM/yyyy 00:00. O Excel guarda datas como dias desde 30/12/1899.
    private static func date(_ cell: Cell) -> String? {
        switch cell {
        case .number(let serial):
            guard serial > 1, serial < 200_000 else { return nil }
            // Algoritmo de datas civis: desloca para a era iniciada em 01/03/0000.
            let z = Int(serial) - 25_569 + 719_468
            let era = z / 146_097
            let doe = z - era * 146_097
            let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
            let mp = (5 * doy + 2) / 153
            let day = doy - (153 * mp + 2) / 5 + 1
            let month = mp < 10 ? mp + 3 : mp - 9
            let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
            return String(format: "%02d/%02d/%04d 00:00", day, month, year)
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "/")
            guard parts.count == 3, parts[0].count == 2, parts[1].count == 2, parts[2].count == 4,
                  Int(parts[0]) != nil, Int(parts[1]) != nil, Int(parts[2]) != nil else { return nil }
            return "\(trimmed) 00:00"
        }
    }
}
