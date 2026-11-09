import Foundation

private struct PersistedState: Codable {
    var lancamentos: [Lancamento] = []
    var balances: [DailyBalance] = []
    var invoices: [CardInvoice] = []
    var classification = UserClassification()
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

        if let holder = parsed.holderName {
            classification.holderName = holder
            classification.ownNames.insert(holder.folded)
        }

        let repeated = parsed.lancamentos.count - fresh.count
        importMessage = "\(fresh.count) lançamentos novos importados, \(repeated) já existiam."
        recompute()
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
        classification = state.classification
    }

    private func save() {
        let state = PersistedState(lancamentos: lancamentos, balances: balances, invoices: invoices, classification: classification)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
