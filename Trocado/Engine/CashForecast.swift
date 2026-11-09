import Foundation

/// Data de calendário, sem hora nem fuso.
struct Day: Codable, Hashable, Comparable {
    var year: Int
    var month: Int
    var day: Int

    static let distantPast = Day(year: 1900, month: 1, day: 1)

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date) {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 2000, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// dd/MM/yyyy
    init?(brazilian text: String) {
        let parts = text.split(separator: "/")
        guard parts.count == 3, let day = Int(parts[0]), let month = Int(parts[1]), let year = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    static var today: Day { Day(date: Date()) }

    static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    var monthKey: String { String(format: "%04d-%02d", year, month) }
    var short: String { String(format: "%02d/%02d", day, month) }

    static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 4, 6, 9, 11: return 30
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        default: return 31
        }
    }

    /// Dia do mês limitado ao último dia daquele mês.
    func withDay(_ value: Int) -> Day {
        Day(year: year, month: month, day: min(value, Day.daysIn(year: year, month: month)))
    }

    func addingMonths(_ count: Int) -> Day {
        let total = year * 12 + (month - 1) + count
        return Day(year: total / 12, month: total % 12 + 1, day: 1)
    }

    func next() -> Day {
        if day < Day.daysIn(year: year, month: month) { return Day(year: year, month: month, day: day + 1) }
        return addingMonths(1)
    }

    func previous() -> Day {
        if day > 1 { return Day(year: year, month: month, day: day - 1) }
        let earlier = addingMonths(-1)
        return earlier.withDay(31)
    }

    /// 0 = domingo, 6 = sábado.
    var weekday: Int {
        let offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        let adjusted = month < 3 ? year - 1 : year
        return (adjusted + adjusted / 4 - adjusted / 100 + adjusted / 400 + offsets[month - 1] + day) % 7
    }

    /// Contas que vencem no fim de semana são pagas no próximo dia útil.
    var nextBusinessDay: Day {
        var current = self
        while current.weekday == 0 || current.weekday == 6 { current = current.next() }
        return current
    }

    /// Salário que cairia no fim de semana é pago no dia útil anterior.
    var previousBusinessDay: Day {
        var current = self
        while current.weekday == 0 || current.weekday == 6 { current = current.previous() }
        return current
    }

    static func monthsBetween(_ from: String, _ to: String) -> Int? {
        func index(_ key: String) -> Int? {
            let parts = key.split(separator: "-")
            guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
            return year * 12 + month
        }
        guard let start = index(from), let end = index(to) else { return nil }
        return end - start
    }
}

struct CashItem: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var cents: Int
    var isIncome: Bool
    var day: Day
    var repeatsMonthly: Bool
}

struct CashState: Codable {
    var statementBalanceCents: Int?
    var statementDay: Day?
    var manualBalanceCents: Int?
    var manualBalanceDay: Day?
    var items: [CashItem] = []
    var paid: [String: Day] = [:]
    var amountOverrides: [String: Int] = [:]
    var ignoredRules: Set<String> = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statementBalanceCents = try container.decodeIfPresent(Int.self, forKey: .statementBalanceCents)
        statementDay = try container.decodeIfPresent(Day.self, forKey: .statementDay)
        manualBalanceCents = try container.decodeIfPresent(Int.self, forKey: .manualBalanceCents)
        manualBalanceDay = try container.decodeIfPresent(Day.self, forKey: .manualBalanceDay)
        items = try container.decodeIfPresent([CashItem].self, forKey: .items) ?? []
        paid = try container.decodeIfPresent([String: Day].self, forKey: .paid) ?? [:]
        amountOverrides = try container.decodeIfPresent([String: Int].self, forKey: .amountOverrides) ?? [:]
        ignoredRules = try container.decodeIfPresent(Set<String>.self, forKey: .ignoredRules) ?? []
    }
}

enum CashSource: Equatable {
    case recurring
    case salary
    case invoiceExact
    case invoiceEstimate
    case manual
    case installment

    var label: String {
        switch self {
        case .recurring: return "Estimado pelo histórico"
        case .salary: return "Salário estimado"
        case .invoiceExact: return "Fatura importada"
        case .invoiceEstimate: return "Fatura estimada"
        case .manual: return "Adicionado por você"
        case .installment: return "Parcela lançada"
        }
    }
}

struct CashOccurrence: Identifiable {
    let id: String
    let ruleID: String
    let name: String
    let cents: Int
    let day: Day
    let source: CashSource
    let isOverdue: Bool
    var balanceAfter = 0
}

struct CashForecast {
    var hasBalance = false
    var startingCents = 0
    var startingDay = Day.today
    var occurrences: [CashOccurrence] = []
    var payable = 0
    var receivable = 0
    var finalCents = 0
    var lowestCents = 0
    var lowestDay: Day?
}

struct CashInput {
    let lancamentos: [Lancamento]
    let categories: [String: SpendCategory]
    let invoices: [CardInvoice]
    let state: CashState
    let today: Day
}

enum CashForecastEngine {
    private struct Rule {
        let id: String
        let name: String
        let matchKey: String
        let isIncome: Bool
        let dayOfMonth: Int
        let cents: Int
        let window: ClosedRange<Int>
        let source: CashSource
    }

    private static let invoiceRuleID = "fatura-btg"
    private static let invoiceDueDay = 15
    private static let historyMonths = 6

    /// A mesma empresa às vezes aparece com nomes diferentes no extrato.
    private static func merchantKey(_ name: String) -> String {
        let folded = name.folded
        return folded == "ceg" ? "naturgy" : folded
    }

    static func build(_ input: CashInput, until end: Day) -> CashForecast {
        var forecast = CashForecast()
        let state = input.state

        if let day = state.manualBalanceDay, let cents = state.manualBalanceCents,
           state.statementDay.map({ day >= $0 }) ?? true {
            forecast.hasBalance = true
            forecast.startingCents = cents
            forecast.startingDay = day
        } else if let day = state.statementDay, let cents = state.statementBalanceCents {
            forecast.hasBalance = true
            forecast.startingCents = cents
            forecast.startingDay = day
        }
        let base = forecast.startingDay

        let accountItems = input.lancamentos.filter { !$0.isCard && !$0.isManual }
        var seen: [String: [Int]] = [:]
        for item in accountItems {
            let key = "\(merchantKey(item.merchantName))|\(item.cents > 0)|\(item.monthKey)"
            seen[key, default: []].append(Int(item.rawDate.prefix(2)) ?? 0)
        }

        func wasRealized(_ rule: Rule, in month: Day) -> Bool {
            let key = "\(rule.matchKey)|\(rule.isIncome)|\(month.monthKey)"
            return seen[key]?.contains(where: { rule.window.contains($0) }) ?? false
        }

        var rules = detectRules(input, today: base)
        for item in state.items where item.repeatsMonthly {
            rules.append(Rule(
                id: item.id,
                name: item.name,
                matchKey: merchantKey(item.name),
                isIncome: item.isIncome,
                dayOfMonth: item.day.day,
                cents: item.cents,
                window: 1...31,
                source: .manual
            ))
        }

        var list: [CashOccurrence] = []
        var adjustment = 0
        let baseMonth = Day(year: base.year, month: base.month, day: 1)

        func consider(id: String, ruleID: String, name: String, cents: Int, due: Day, source: CashSource) {
            guard !state.ignoredRules.contains(ruleID) else { return }
            let amount = state.amountOverrides[id].map { cents < 0 ? -$0 : $0 } ?? cents
            if let paidDay = state.paid[id] {
                if paidDay >= base { adjustment += amount }
                return
            }
            let overdue = due < base
            let shown = overdue ? base : due
            guard shown <= end else { return }
            list.append(CashOccurrence(id: id, ruleID: ruleID, name: name, cents: amount, day: shown, source: source, isOverdue: overdue))
        }

        var cursor = baseMonth
        while cursor <= end {
            for rule in rules where !wasRealized(rule, in: cursor) {
                let nominal = cursor.withDay(rule.dayOfMonth)
                let due = rule.isIncome ? nominal.previousBusinessDay : nominal.nextBusinessDay
                consider(
                    id: "\(rule.id)|\(cursor.monthKey)",
                    ruleID: rule.id,
                    name: rule.name,
                    cents: rule.isIncome ? rule.cents : -rule.cents,
                    due: due,
                    source: rule.source
                )
            }

            let invoicePaid = accountItems.contains { $0.isBTGInvoicePayment && $0.monthKey == cursor.monthKey }
            if !invoicePaid, let estimate = invoiceAmount(for: cursor.monthKey, input: input, accountItems: accountItems) {
                consider(
                    id: "\(invoiceRuleID)|\(cursor.monthKey)",
                    ruleID: invoiceRuleID,
                    name: "Fatura do cartão BTG",
                    cents: -estimate.cents,
                    due: cursor.withDay(invoiceDueDay).nextBusinessDay,
                    source: estimate.exact ? .invoiceExact : .invoiceEstimate
                )
            }
            cursor = cursor.addingMonths(1)
        }

        for item in state.items where !item.repeatsMonthly {
            consider(
                id: item.id,
                ruleID: item.id,
                name: item.name,
                cents: item.isIncome ? item.cents : -item.cents,
                due: item.day,
                source: .manual
            )
        }

        for item in input.lancamentos where item.isManual {
            guard let day = Day(brazilian: String(item.rawDate.prefix(10))), day > base,
                  (input.categories[item.id] ?? .outros).kind != .neutral else { continue }
            consider(id: "lanc|\(item.id)", ruleID: "lanc|\(item.id)", name: item.description, cents: item.cents, due: day, source: .installment)
        }

        list.sort {
            if $0.day != $1.day { return $0.day < $1.day }
            return $0.cents > $1.cents
        }

        forecast.startingCents += adjustment
        var running = forecast.startingCents
        forecast.lowestCents = running
        for index in list.indices {
            running += list[index].cents
            list[index].balanceAfter = running
            if list[index].cents > 0 {
                forecast.receivable += list[index].cents
            } else {
                forecast.payable -= list[index].cents
            }
            if running < forecast.lowestCents {
                forecast.lowestCents = running
                forecast.lowestDay = list[index].day
            }
        }
        forecast.occurrences = list
        forecast.finalCents = running
        return forecast
    }

    private static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private static func detectRules(_ input: CashInput, today: Day) -> [Rule] {
        let firstOfMonth = Day(year: today.year, month: today.month, day: 1)
        let window = Set((1...historyMonths).map { firstOfMonth.addingMonths(-$0).monthKey })
        let accountItems = input.lancamentos.filter { !$0.isCard && !$0.isManual && window.contains($0.monthKey) }

        var rules: [Rule] = []

        // Salários: costumam cair em duas datas por mês.
        let salaries = accountItems.filter {
            input.categories[$0.id] == .salario && $0.type.folded.contains("pagamento de salario")
        }
        for (index, range) in [1...20, 21...31].enumerated() {
            let group = salaries
                .filter { range.contains(Int($0.rawDate.prefix(2)) ?? 0) }
                .sorted { $0.sortKey < $1.sortKey }
            guard group.count >= 3, let last = group.last else { continue }
            rules.append(Rule(
                id: "salario|\(index + 1)",
                name: index == 0 ? "Salário (1ª parte)" : "Salário (2ª parte)",
                matchKey: merchantKey(last.merchantName),
                isIncome: true,
                dayOfMonth: median(group.map { Int($0.rawDate.prefix(2)) ?? 15 }),
                cents: median(group.suffix(3).map(\.cents)),
                window: range,
                source: .salary
            ))
        }

        // Contas que saem uma vez por mês, com valor parecido.
        var groups: [String: [Lancamento]] = [:]
        for item in accountItems where item.cents < 0 && !item.isBTGInvoicePayment {
            let category = input.categories[item.id] ?? .outros
            guard category.kind == .expense else { continue }
            groups[merchantKey(item.merchantName), default: []].append(item)
        }

        for (key, items) in groups {
            var monthly: [String: Int] = [:]
            for item in items { monthly[item.monthKey, default: 0] -= item.cents }
            guard monthly.count >= 3, items.count <= monthly.count + 1,
                  let low = monthly.values.min(), let high = monthly.values.max(),
                  low > 0, high <= low * 2 else { continue }

            let lastMonths = monthly.keys.sorted().suffix(3).compactMap { monthly[$0] }
            let amount = median(lastMonths)
            guard amount >= 10_000 else { continue }
            let newest = items.max { $0.sortKey < $1.sortKey }

            rules.append(Rule(
                id: "auto|\(key)",
                name: newest?.merchantName ?? key,
                matchKey: key,
                isIncome: false,
                dayOfMonth: median(items.map { Int($0.rawDate.prefix(2)) ?? 1 }),
                cents: amount,
                window: 1...31,
                source: .recurring
            ))
        }
        return rules
    }

    private static func invoiceAmount(
        for month: String,
        input: CashInput,
        accountItems: [Lancamento]
    ) -> (cents: Int, exact: Bool)? {
        if let imported = input.invoices.first(where: { $0.dueMonth == month }) {
            return (imported.totalCents, true)
        }

        if let latest = input.invoices.map(\.dueMonth).max(), let distance = Day.monthsBetween(latest, month), distance > 0 {
            var continuing = 0
            var newByInvoice: [String: Int] = [:]
            for item in input.lancamentos where item.isCard && item.cents < 0 {
                let parcel = item.installment
                if item.monthKey == latest, let parcel, parcel.current + distance <= parcel.total {
                    continuing -= item.cents
                }
                if parcel == nil || parcel?.current == 1 {
                    newByInvoice[item.monthKey, default: 0] -= item.cents
                }
            }
            let average = newByInvoice.isEmpty ? 0 : newByInvoice.values.reduce(0, +) / newByInvoice.count
            return (continuing + average, false)
        }

        let payments = accountItems.filter(\.isBTGInvoicePayment).sorted { $0.sortKey < $1.sortKey }
        guard !payments.isEmpty else { return nil }
        return (median(payments.suffix(3).map { -$0.cents }), false)
    }
}
