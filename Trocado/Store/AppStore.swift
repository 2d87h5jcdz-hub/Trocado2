import Foundation

private struct PersistedState: Codable {
    var lancamentos: [Lancamento] = []
    var balances: [DailyBalance] = []
    var invoices: [CardInvoice] = []
    var classification = UserClassification()
    var cash = CashState()

    init() {}

    // Campos ausentes ganham valor padrão, para atualizações do app não perderem os dados já salvos.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lancamentos = try container.decodeIfPresent([Lancamento].self, forKey: .lancamentos) ?? []
        balances = try container.decodeIfPresent([DailyBalance].self, forKey: .balances) ?? []
        invoices = try container.decodeIfPresent([CardInvoice].self, forKey: .invoices) ?? []
        classification = try container.decodeIfPresent(UserClassification.self, forKey: .classification) ?? UserClassification()
        cash = try container.decodeIfPresent(CashState.self, forKey: .cash) ?? CashState()
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var lancamentos: [Lancamento] = []
    @Published private(set) var balances: [DailyBalance] = []
    @Published private(set) var classification = UserClassification()
    @Published private(set) var categories: [String: SpendCategory] = [:]
    @Published private(set) var summaries: [MonthSummary] = []
    @Published private(set) var ownCandidates: [OwnNameCandidate] = []
    @Published private(set) var insights: [Insight] = []
    @Published var importMessage: String?
    @Published var isImporting = false
    @Published private(set) var invoices: [CardInvoice] = []
    @Published var pendingEncryptedFile: Data?
    @Published private(set) var cash = CashState()
    @Published private(set) var lastPasswordWasWrong = false

    private let categorizer = Categorizer()

    private var fileURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("trocado.json")
    }

    init() {
        load()
        recompute()
    }

    var months: [String] {
        summaries.map(\.month).sorted(by: >)
    }

    var currentMonthKey: String {
        let parts = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    func category(of item: Lancamento) -> SpendCategory {
        categories[item.id] ?? .outros
    }

    func summary(for month: String) -> MonthSummary? {
        summaries.first { $0.month == month }
    }

    var analysisInput: AnalysisInput {
        AnalysisInput(
            lancamentos: lancamentos,
            categories: categories,
            summaries: summaries,
            balances: balances,
            currentMonth: currentMonthKey
        )
    }

    var advisorPrompt: String {
        InsightEngine.advisorPrompt(analysisInput, insights: insights)
    }

    // MARK: Importação

    func importFile(at url: URL) async {
        isImporting = true
        defer { isImporting = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            await process(data, password: Keychain.readPassword(), rememberPassword: false)
        } catch {
            importMessage = error.localizedDescription
        }
    }

    func submitPassword(_ password: String) {
        guard let data = pendingEncryptedFile else { return }
        pendingEncryptedFile = nil
        isImporting = true
        Task {
            await process(data, password: password, rememberPassword: true)
            isImporting = false
        }
    }

    private func process(_ data: Data, password: String?, rememberPassword: Bool) async {
        do {
            let file = try await Task.detached(priority: .userInitiated) {
                try ImportRouter.read(data: data, password: password)
            }.value
            if rememberPassword, let password { Keychain.savePassword(password) }
            lastPasswordWasWrong = false
            switch file {
            case .statement(let statement): merge(statement)
            case .invoice(let invoice): merge(invoice)
            }
        } catch XLSError.passwordRequired {
            lastPasswordWasWrong = false
            pendingEncryptedFile = data
        } catch XLSError.wrongPassword {
            Keychain.deletePassword()
            lastPasswordWasWrong = true
            pendingEncryptedFile = data
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private func merge(_ invoice: ParsedInvoice) {
        let known = Set(lancamentos.map(\.id))
        let fresh = invoice.lancamentos.filter { !known.contains($0.id) }
        lancamentos.append(contentsOf: fresh)
        lancamentos.sort { $0.sortKey > $1.sortKey }
        invoices.removeAll { $0.dueMonth == invoice.dueMonth }
        invoices.append(CardInvoice(dueMonth: invoice.dueMonth, totalCents: invoice.totalCents))

        var message = "Fatura de \(Format.month(invoice.dueMonth)): \(fresh.count) compras novas."
        let paid = lancamentos
            .filter { $0.isBTGInvoicePayment && $0.monthKey == invoice.dueMonth }
            .reduce(0) { $0 - $1.cents }
        if paid > 0 {
            if abs(paid - invoice.totalCents) <= 100 {
                message += " Bate com o pagamento feito pela conta, que não será contado duas vezes."
            } else {
                message += " Atenção: a fatura é de \(Format.brl(invoice.totalCents)) e a conta pagou \(Format.brl(paid))."
            }
        }
        importMessage = message
        recompute()
        save()
    }

    private func merge(_ parsed: ParsedStatement) {
        let known = Set(lancamentos.map(\.id))
        let fresh = parsed.lancamentos.filter { !known.contains($0.id) }
        lancamentos.append(contentsOf: fresh)
        lancamentos.sort { $0.sortKey > $1.sortKey }

        var byDay = Dictionary(balances.map { ($0.dayKey, $0) }, uniquingKeysWith: { _, new in new })
        for balance in parsed.balances { byDay[balance.dayKey] = balance }
        balances = byDay.values.sorted { $0.dayKey < $1.dayKey }

        if let cents = parsed.currentBalanceCents, let day = parsed.periodEnd,
           cash.statementDay.map({ day >= $0 }) ?? true {
            cash.statementBalanceCents = cents
            cash.statementDay = day
        }

        if let holder = parsed.holderName {
            classification.holderName = holder
            classification.ownNames.insert(holder.folded)
        }

        let repeated = parsed.lancamentos.count - fresh.count
        importMessage = "\(fresh.count) lançamentos novos importados, \(repeated) já existiam."
        recompute()
        save()
    }

    // MARK: Lançamentos manuais

    /// `cents` é o valor de cada parcela, sempre positivo; o sinal vem da categoria.
    func addManualEntry(description: String, cents: Int, date: Date, category: SpendCategory, installments: Int) {
        let name = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, cents > 0 else { return }

        let total = max(installments, 1)
        let group = UUID().uuidString
        let signed = category.kind == .expense ? -cents : cents
        let calendar = Calendar.current

        for number in 1...total {
            guard let when = calendar.date(byAdding: .month, value: number - 1, to: date) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: when)
            let rawDate = String(
                format: "%02d/%02d/%04d %02d:%02d",
                parts.day ?? 1, parts.month ?? 1, parts.year ?? 2000, parts.hour ?? 0, parts.minute ?? 0
            )
            let id = "manual|\(group)|\(number)"
            lancamentos.append(Lancamento(
                id: id,
                rawDate: rawDate,
                bankCategory: "",
                type: "Lançamento manual",
                description: total > 1 ? "\(name) (\(number)/\(total))" : name,
                cents: signed
            ))
            classification.overrides[id] = category
        }

        lancamentos.sort { $0.sortKey > $1.sortKey }
        recompute()
        save()
    }

    func deleteManualEntry(_ item: Lancamento, includingInstallments: Bool) {
        guard item.isManual else { return }
        let removed = lancamentos.filter {
            includingInstallments ? $0.manualGroup == item.manualGroup : $0.id == item.id
        }
        let ids = Set(removed.map(\.id))
        lancamentos.removeAll { ids.contains($0.id) }
        for id in ids { classification.overrides[id] = nil }
        recompute()
        save()
    }

    // MARK: Caixa

    func forecast(until end: Day) -> CashForecast {
        CashForecastEngine.build(CashInput(
            lancamentos: lancamentos,
            categories: categories,
            invoices: invoices,
            state: cash,
            today: .today
        ), until: end)
    }

    func setManualBalance(cents: Int) {
        cash.manualBalanceCents = cents
        cash.manualBalanceDay = .today
        // O saldo digitado já reflete o que foi pago até agora.
        for key in Array(cash.paid.keys) { cash.paid[key] = .distantPast }
        save()
    }

    func addCashItem(name: String, cents: Int, isIncome: Bool, day: Day, repeatsMonthly: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, cents > 0 else { return }
        cash.items.append(CashItem(
            id: "manual|\(UUID().uuidString)",
            name: trimmed,
            cents: cents,
            isIncome: isIncome,
            day: day,
            repeatsMonthly: repeatsMonthly
        ))
        save()
    }

    func markSettled(_ occurrence: CashOccurrence) {
        cash.paid[occurrence.id] = .today
        save()
    }

    func setAmount(_ cents: Int, for occurrence: CashOccurrence) {
        cash.amountOverrides[occurrence.id] = cents
        save()
    }

    func stopForecasting(_ occurrence: CashOccurrence) {
        if occurrence.source == .manual {
            cash.items.removeAll { $0.id == occurrence.ruleID }
        } else {
            cash.ignoredRules.insert(occurrence.ruleID)
        }
        save()
    }

    // MARK: Ajustes do usuário

    func setCategory(_ category: SpendCategory, for item: Lancamento, applyToAll: Bool) {
        if applyToAll {
            let key = item.merchantRuleKey
            classification.merchantRules[key] = category
            for other in lancamentos where other.merchantRuleKey == key {
                classification.overrides[other.id] = nil
            }
        } else {
            classification.overrides[item.id] = category
        }
        recompute()
        save()
    }

    func resolveOwnName(_ name: String, isMine: Bool) {
        if isMine {
            classification.ownNames.insert(name)
            classification.notOwnNames.remove(name)
        } else {
            classification.notOwnNames.insert(name)
            classification.ownNames.remove(name)
        }
        recompute()
        save()
    }

    func eraseEverything() {
        lancamentos = []
        balances = []
        invoices = []
        cash = CashState()
        classification = UserClassification()
        Keychain.deletePassword()
        try? FileManager.default.removeItem(at: fileURL)
        recompute()
    }

    // MARK: Cálculo

    private func recompute() {
        var newCategories: [String: SpendCategory] = [:]
        var byMonth: [String: MonthSummary] = [:]
        let detailedMonths = Set(invoices.map(\.dueMonth))
        let lookup = categorizer.bankLookup(from: lancamentos)

        for item in lancamentos {
            // Com a fatura importada, as compras contam uma a uma e o pagamento dela deixa de contar.
            let category: SpendCategory = item.isBTGInvoicePayment && detailedMonths.contains(item.monthKey)
                ? .faturaDetalhada
                : categorizer.category(for: item, user: classification, lookup: lookup)
            newCategories[item.id] = category

            var summary = byMonth[item.monthKey] ?? MonthSummary(month: item.monthKey)
            switch category.kind {
            case .income:
                summary.income += item.cents
                summary.byCategory[category, default: 0] += item.cents
            case .expense:
                summary.expense -= item.cents
                summary.byCategory[category, default: 0] -= item.cents
            case .neutral:
                break
            }
            byMonth[item.monthKey] = summary
        }

        categories = newCategories
        summaries = byMonth.values.sorted { $0.month < $1.month }
        ownCandidates = findOwnCandidates()
        insights = lancamentos.isEmpty ? [] : InsightEngine.analyze(analysisInput)
    }

    /// Nomes muito parecidos com o do titular podem ser outra conta dele ou um parente.
    /// Como só a pessoa sabe, o app pergunta em vez de decidir.
    private func findOwnCandidates() -> [OwnNameCandidate] {
        guard let holder = classification.holderName?.folded else { return [] }
        var totals: [String: (inCents: Int, outCents: Int, count: Int)] = [:]

        for item in lancamentos {
            let type = item.type.folded
            guard type.contains("pix") || type.contains("transfer") else { continue }
            let name = item.description.folded
            guard !classification.ownNames.contains(name),
                  !classification.notOwnNames.contains(name),
                  name.split(separator: " ").count >= 3,
                  holder.hasPrefix(name + " ") || name.hasPrefix(holder + " ") else { continue }
            var entry = totals[name] ?? (inCents: 0, outCents: 0, count: 0)
            if item.cents > 0 { entry.inCents += item.cents } else { entry.outCents -= item.cents }
            entry.count += 1
            totals[name] = entry
        }

        return totals.map { name, value in
            OwnNameCandidate(name: name, inCents: value.inCents, outCents: value.outCents, count: value.count)
        }
        .sorted { $0.count > $1.count }
    }

    // MARK: Persistência

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        lancamentos = state.lancamentos
        balances = state.balances
        invoices = state.invoices
        cash = state.cash
        classification = state.classification
    }

    private func save() {
        var state = PersistedState()
        state.lancamentos = lancamentos
        state.balances = balances
        state.invoices = invoices
        state.classification = classification
        state.cash = cash
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
