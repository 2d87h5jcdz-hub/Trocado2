import Foundation

struct AnalysisInput {
    let lancamentos: [Lancamento]
    let categories: [String: SpendCategory]
    let summaries: [MonthSummary]
    let balances: [DailyBalance]
    let currentMonth: String
}

struct RecurringExpense: Identifiable {
    let name: String
    let average: Int
    let months: Int
    var id: String { name }
}

/// Toda a matemática fica aqui, em código determinístico. A IA só redige em cima destes números.
enum InsightEngine {
    static let windowSize = 6

    static func window(_ input: AnalysisInput) -> [MonthSummary] {
        Array(input.summaries
            .filter { $0.month < input.currentMonth }
            .sorted { $0.month < $1.month }
            .suffix(windowSize))
    }

    static func analyze(_ input: AnalysisInput) -> [Insight] {
        let months = window(input)
        guard months.count >= 2 else {
            return [Insight(
                id: "pouco-dado",
                symbol: "calendar",
                title: "Preciso de pelo menos 2 meses fechados",
                detail: "Importe um período maior para eu comparar seus gastos.",
                monthlySaving: nil
            )]
        }

        var result: [Insight] = []
        let count = months.count

        func average(_ category: SpendCategory) -> Int {
            months.reduce(0) { $0 + ($1.byCategory[category] ?? 0) } / count
        }

        // Resultado do mês sem receitas extraordinárias
        let income = months.reduce(0) { $0 + $1.income } / count
        let expense = months.reduce(0) { $0 + $1.expense } / count
        let bonus = months.reduce(0) { $0 + abs($1.byCategory[.bonus] ?? 0) } / count
        let regular = income - bonus - expense
        result.append(Insight(
            id: "resultado",
            symbol: regular >= 0 ? "checkmark.seal" : "exclamationmark.triangle",
            title: regular >= 0
                ? "Sem bônus, sobram \(Format.brl(regular)) por mês"
                : "Sem bônus, faltam \(Format.brl(-regular)) por mês",
            detail: "Média dos últimos \(count) meses fechados: \(Format.brl(income - bonus)) de entradas regulares e \(Format.brl(expense)) de gastos.",
            monthlySaving: nil
        ))

        // Fatura de cartão esconde o detalhamento
        let card = average(.cartao)
        if expense > 0, card * 100 / expense >= 30 {
            result.append(Insight(
                id: "cartao",
                symbol: "creditcard",
                title: "\(card * 100 / expense)% dos gastos estão dentro de faturas",
                detail: "São \(Format.brl(card)) por mês em que o extrato não mostra o que foi comprado. É aí que costuma estar a maior oportunidade de economia.",
                monthlySaving: nil
            ))
        }

        // Categorias que subiram no último mês fechado
        if count >= 2, let last = months.last {
            let previous = months.dropLast().suffix(3)
            var rises: [(SpendCategory, Int, Int)] = []
            for category in SpendCategory.allCases where category.kind == .expense {
                let current = last.byCategory[category] ?? 0
                let base = previous.reduce(0) { $0 + ($1.byCategory[category] ?? 0) } / previous.count
                if base > 0, current * 100 > base * 125, current - base >= 10_000 {
                    rises.append((category, current, base))
                }
            }
            for (category, current, base) in rises.sorted(by: { $0.1 - $0.2 > $1.1 - $1.2 }).prefix(3) {
                result.append(Insight(
                    id: "alta-\(category.rawValue)",
                    symbol: category.symbol,
                    title: "\(category.title) subiu em \(Format.month(last.month))",
                    detail: "\(Format.brl(current)) contra uma média de \(Format.brl(base)) nos meses anteriores.",
                    monthlySaving: current - base
                ))
            }
        }

        // Comer fora
        let food = average(.alimentacao)
        if food >= 20_000 {
            result.append(Insight(
                id: "comer-fora",
                symbol: "fork.knife",
                title: "Comer fora custa \(Format.brl(food)) por mês",
                detail: "Simulação: trocar 1 a cada 4 refeições fora por comida de casa libera cerca de \(Format.brl(food / 4)).",
                monthlySaving: food / 4
            ))
        }

        // Telefonia e internet
        let recurring = recurringExpenses(input, months: months)
        let telecomWords = ["telefonica", "vivo", "claro", "tim", "oi", "net", "nextel", "algar"]
        let telecom = recurring.filter { item in
            let first = item.name.folded.split(separator: " ").first.map(String.init) ?? ""
            return telecomWords.contains(first)
        }
        let telecomTotal = telecom.reduce(0) { $0 + $1.average }
        if telecomTotal >= 15_000 {
            result.append(Insight(
                id: "telefonia",
                symbol: "antenna.radiowaves.left.and.right",
                title: "Telefone e internet: \(Format.brl(telecomTotal)) por mês",
                detail: "Simulação: renegociar ou trocar de plano com 15% de redução libera cerca de \(Format.brl(telecomTotal * 15 / 100)).",
                monthlySaving: telecomTotal * 15 / 100
            ))
        }

        // Recorrentes
        if !recurring.isEmpty {
            let top = recurring.prefix(5).map { "\($0.name) (\(Format.brl($0.average)))" }.joined(separator: ", ")
            let total = recurring.reduce(0) { $0 + $1.average }
            result.append(Insight(
                id: "recorrentes",
                symbol: "repeat",
                title: "\(recurring.count) gastos recorrentes somam \(Format.brl(total)) por mês",
                detail: "Maiores: \(top). Vale revisar se todos ainda fazem sentido.",
                monthlySaving: nil
            ))
        }

        // Crédito
        let credit = average(.credito)
        if credit > 0 {
            result.append(Insight(
                id: "credito",
                symbol: "percent",
                title: "\(Format.brl(credit)) por mês em crédito e financiamento",
                detail: "Se houver desconto por antecipação, priorize quitar primeiro o contrato de juros mais altos.",
                monthlySaving: nil
            ))
        }

        // Pix para pessoas
        let people = average(.pessoas)
        if people >= 50_000 {
            result.append(Insight(
                id: "pessoas",
                symbol: "person.2",
                title: "\(Format.brl(people)) por mês em Pix para pessoas",
                detail: "O extrato não diz o motivo. Classifique os mais frequentes (diarista, aluguel, ajuda à família) para o painel ficar fiel.",
                monthlySaving: nil
            ))
        }

        // Parcelas que já estão contratadas
        if let latest = input.lancamentos.filter(\.isCard).map(\.monthKey).max() {
            var future = 0
            var next = 0
            var open = 0
            for item in input.lancamentos where item.isCard && item.monthKey == latest && item.cents < 0 {
                guard let parcel = item.installment, parcel.current < parcel.total else { continue }
                future += -item.cents * (parcel.total - parcel.current)
                next += -item.cents
                open += 1
            }
            if open > 0 {
                result.append(Insight(
                    id: "parcelas",
                    symbol: "calendar.badge.clock",
                    title: "\(Format.brl(future)) já comprometidos em parcelas",
                    detail: "\(open) compras seguem depois da fatura de \(Format.month(latest)). Só a próxima fatura já começa com \(Format.brl(next)).",
                    monthlySaving: nil
                ))
            }
        }

        // Aperto no caixa
        if let firstMonth = months.first?.month, let lastMonth = months.last?.month {
            let tight = input.balances.filter {
                let month = String($0.dayKey.prefix(7))
                return month >= firstMonth && month <= lastMonth && $0.cents < 20_000
            }.count
            let negative = months.filter { $0.net < 0 }.count
            if tight >= 3 || negative >= 2 {
                result.append(Insight(
                    id: "aperto",
                    symbol: "gauge.with.dots.needle.33percent",
                    title: "Caixa apertado em alguns períodos",
                    detail: "\(tight) dias fecharam com menos de R$ 200 e \(negative) de \(count) meses gastaram mais do que entrou.",
                    monthlySaving: nil
                ))
            }
        }

        let withSaving = result.filter { $0.monthlySaving != nil }.sorted { ($0.monthlySaving ?? 0) > ($1.monthlySaving ?? 0) }
        let others = result.filter { $0.monthlySaving == nil }
        return Array(others.prefix(1)) + withSaving + Array(others.dropFirst())
    }

    static func recurringExpenses(_ input: AnalysisInput, months: [MonthSummary]) -> [RecurringExpense] {
        let allowed = Set(months.map(\.month))
        let excluded: Set<SpendCategory> = [.pessoas, .cartao, .interno, .investimentos, .outros]
        var byMerchant: [String: (name: String, monthly: [String: Int])] = [:]

        for item in input.lancamentos where item.cents < 0 && allowed.contains(item.monthKey) {
            let category = input.categories[item.id] ?? .outros
            guard category.kind == .expense, !excluded.contains(category) else { continue }
            let key = item.merchantName.folded
            var entry: (name: String, monthly: [String: Int]) = byMerchant[key] ?? (name: item.merchantName, monthly: [:])
            entry.monthly[item.monthKey, default: 0] += -item.cents
            byMerchant[key] = entry
        }

        var result: [RecurringExpense] = []
        for entry in byMerchant.values where entry.monthly.count >= 3 {
            let values = entry.monthly.values.sorted()
            guard let low = values.first, let high = values.last, low > 0, high * 100 <= low * 180 else { continue }
            result.append(RecurringExpense(
                name: entry.name,
                average: values.reduce(0, +) / values.count,
                months: values.count
            ))
        }
        return result.sorted { $0.average > $1.average }
    }

    /// Resumo agregado entregue à IA local. Não inclui nomes de pessoas.
    static func advisorPrompt(_ input: AnalysisInput, insights: [Insight]) -> String {
        let months = window(input)
        var lines: [String] = ["Médias mensais dos últimos \(months.count) meses fechados:"]
        if !months.isEmpty {
            for category in SpendCategory.allCases where category.kind != .neutral {
                let total = months.reduce(0) { $0 + ($1.byCategory[category] ?? 0) } / months.count
                if abs(total) >= 1_000 { lines.append("- \(category.title): \(Format.brl(total))") }
            }
        }
        lines.append("")
        lines.append("Fatos calculados:")
        for insight in insights {
            lines.append("- \(insight.title). \(insight.detail)")
        }
        lines.append("")
        lines.append("Com base apenas nesses dados, escreva até 5 sugestões concretas de economia, da mais valiosa para a menos valiosa.")
        return lines.joined(separator: "\n")
    }
}
