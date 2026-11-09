import SwiftUI

enum CategoryKind: String, Codable {
    case income, expense, neutral
}

enum SpendCategory: String, Codable, CaseIterable, Identifiable {
    case salario, bonus, reembolso, outrasEntradas
    case moradia, contas, cartao, supermercado, alimentacao, transporte, saude, educacao
    case lazer, compras, cuidados, pets, assinaturas, impostos, credito, pessoas, outros
    case interno, investimentos, faturaDetalhada

    var id: String { rawValue }

    var title: String {
        switch self {
        case .salario: return "Salário"
        case .bonus: return "Bônus e PLR"
        case .reembolso: return "Reembolso"
        case .outrasEntradas: return "Outras entradas"
        case .moradia: return "Moradia"
        case .contas: return "Contas da casa"
        case .cartao: return "Fatura de cartão"
        case .supermercado: return "Supermercado"
        case .alimentacao: return "Alimentação fora"
        case .transporte: return "Transporte"
        case .saude: return "Saúde"
        case .educacao: return "Educação"
        case .lazer: return "Lazer"
        case .compras: return "Compras"
        case .cuidados: return "Cuidados pessoais"
        case .pets: return "Pets"
        case .assinaturas: return "Assinaturas"
        case .impostos: return "Impostos e taxas"
        case .credito: return "Crédito e financiamento"
        case .pessoas: return "Pix para pessoas"
        case .outros: return "Outros gastos"
        case .interno: return "Entre minhas contas"
        case .investimentos: return "Investimentos"
        case .faturaDetalhada: return "Fatura já detalhada"
        }
    }

    var symbol: String {
        switch self {
        case .salario: return "banknote"
        case .bonus: return "star.circle"
        case .reembolso: return "arrow.uturn.backward.circle"
        case .outrasEntradas: return "tray.and.arrow.down"
        case .moradia: return "house"
        case .contas: return "bolt"
        case .cartao: return "creditcard"
        case .supermercado: return "cart"
        case .alimentacao: return "fork.knife"
        case .transporte: return "car"
        case .saude: return "cross.case"
        case .educacao: return "book"
        case .lazer: return "ticket"
        case .compras: return "bag"
        case .cuidados: return "scissors"
        case .pets: return "pawprint"
        case .assinaturas: return "repeat"
        case .impostos: return "building.columns"
        case .credito: return "percent"
        case .pessoas: return "person.2"
        case .outros: return "questionmark.circle"
        case .interno: return "arrow.left.arrow.right"
        case .investimentos: return "chart.line.uptrend.xyaxis"
        case .faturaDetalhada: return "checkmark.circle"
        }
    }

    var kind: CategoryKind {
        switch self {
        case .salario, .bonus, .reembolso, .outrasEntradas: return .income
        case .interno, .investimentos, .faturaDetalhada: return .neutral
        default: return .expense
        }
    }

    var color: Color {
        switch kind {
        case .income: return .green
        case .neutral: return .gray
        case .expense:
            switch self {
            case .moradia: return .indigo
            case .contas: return .orange
            case .cartao: return .purple
            case .supermercado: return .mint
            case .alimentacao: return .red
            case .transporte: return .blue
            case .saude: return .pink
            case .educacao: return .cyan
            case .pessoas: return .brown
            default: return .teal
            }
        }
    }
}

struct Lancamento: Codable, Identifiable, Hashable {
    let id: String
    /// Como vem no extrato: dd/MM/yyyy HH:mm
    let rawDate: String
    let bankCategory: String
    let type: String
    let description: String
    let cents: Int
    /// Mês do pagamento da fatura ("2026-10"); nulo para lançamentos da conta.
    var billingMonth: String? = nil

    private var day: Substring { rawDate.prefix(2) }
    private var month: Substring { rawDate.dropFirst(3).prefix(2) }
    private var year: Substring { rawDate.dropFirst(6).prefix(4) }
    private var time: Substring { rawDate.dropFirst(11).prefix(5) }

    var monthKey: String { billingMonth ?? "\(year)-\(month)" }
    var dayKey: String { "\(year)-\(month)-\(day)" }
    var sortKey: String { "\(year)-\(month)-\(day) \(time)" }
    var shortDate: String { isCard ? "\(day)/\(month) · crédito" : "\(day)/\(month) \(time)" }
    var isCard: Bool { billingMonth != nil }

    var isBTGInvoicePayment: Bool {
        !isCard && type.folded.contains("pagamento de fatura") && description.folded.contains("btg")
    }

    /// "Amazon (3/10)" vira parcela 3 de 10.
    var installment: (current: Int, total: Int)? {
        guard description.hasSuffix(")"), let open = description.range(of: " (", options: .backwards) else { return nil }
        let parts = description[open.upperBound...].dropLast().split(separator: "/")
        guard parts.count == 2, let current = Int(parts[0]), let total = Int(parts[1]) else { return nil }
        return (current, total)
    }

    /// Nome do estabelecimento, sem o sufixo de parcela.
    var merchantName: String {
        guard installment != nil, let open = description.range(of: " (", options: .backwards) else { return description }
        return String(description[..<open.lowerBound])
    }

    /// Regras aprendidas valem só para a mesma direção: pagar alguém não é o mesmo que receber dele.
    var merchantRuleKey: String { "\(merchantName.folded)|\(cents < 0 ? "saida" : "entrada")" }
}

struct DailyBalance: Codable, Hashable {
    let dayKey: String
    let cents: Int
}

struct MonthSummary: Identifiable {
    let month: String
    var income = 0
    var expense = 0
    var byCategory: [SpendCategory: Int] = [:]
    var id: String { month }
    var net: Int { income - expense }
}

struct UserClassification: Codable {
    var overrides: [String: SpendCategory] = [:]
    var merchantRules: [String: SpendCategory] = [:]
    var ownNames: Set<String> = []
    var notOwnNames: Set<String> = []
    var holderName: String?
}

struct CardInvoice: Codable, Hashable {
    let dueMonth: String
    let totalCents: Int
}

struct OwnNameCandidate: Identifiable {
    let name: String
    let inCents: Int
    let outCents: Int
    let count: Int
    var id: String { name }
}

struct Insight: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let monthlySaving: Int?
}

enum Format {
    private static let money: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "pt_BR")
        f.currencyCode = "BRL"
        return f
    }()

    static func brl(_ cents: Int) -> String {
        let value = NSDecimalNumber(value: cents).dividing(by: NSDecimalNumber(value: 100))
        return money.string(from: value) ?? "R$ \(Double(cents) / 100)"
    }

    private static let monthNames = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]

    /// "2026-03" vira "mar/26".
    static func month(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let m = Int(parts[1]), (1...12).contains(m) else { return key }
        return "\(monthNames[m - 1])/\(parts[0].suffix(2))"
    }
}

extension String {
    /// Sem acentos, minúsculas e sem espaços nas pontas.
    var folded: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
