import SwiftUI
import Charts

struct SummaryView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showImporter: Bool
    @State private var selectedMonth: String?

    private var month: String? {
        if let selectedMonth, store.months.contains(selectedMonth) { return selectedMonth }
        return store.months.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let month, let summary = store.summary(for: month) {
                    content(month: month, summary: summary)
                } else {
                    EmptyImportView(showImporter: $showImporter)
                }
            }
            .navigationTitle("Resumo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Importar extrato")
                }
            }
        }
    }

    private func content(month: String, summary: MonthSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Menu {
                    ForEach(store.months, id: \.self) { key in
                        Button(Format.month(key)) { selectedMonth = key }
                    }
                } label: {
                    Label(Format.month(month), systemImage: "calendar")
                        .font(.headline)
                }

                HStack(spacing: 10) {
                    StatTile(title: "Entradas", value: summary.income, color: .green)
                    StatTile(title: "Gastos", value: summary.expense, color: .red)
                    StatTile(title: "Resultado", value: summary.net, color: summary.net >= 0 ? .green : .red)
                }

                ForEach(store.ownCandidates) { candidate in
                    OwnNameCard(candidate: candidate)
                }

                expensesChart(summary)
                trendChart()
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private func expensesChart(_ summary: MonthSummary) -> some View {
        let rows: [CategoryAmount] = summary.byCategory
            .filter { $0.key.kind == .expense && $0.value > 0 }
            .map { CategoryAmount(category: $0.key, cents: $0.value) }
            .sorted { $0.cents > $1.cents }

        return VStack(alignment: .leading, spacing: 12) {
            Text("Para onde foi").font(.headline)
            if rows.isEmpty {
                Text("Sem gastos neste mês.").foregroundStyle(.secondary)
            } else {
                Chart(rows) { row in
                    BarMark(
                        x: .value("Valor", Double(row.cents) / 100),
                        y: .value("Categoria", row.category.title)
                    )
                    .foregroundStyle(row.category.color)
                    .annotation(position: .trailing) {
                        Text(Format.brl(row.cents))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(rows.count) * 34 + 16)
                .padding(.trailing, 72)
            }
        }
        .card()
    }

    private func trendChart() -> some View {
        let recent = Array(store.summaries.suffix(12))
        return VStack(alignment: .leading, spacing: 12) {
            Text("Entradas e gastos por mês").font(.headline)
            Chart {
                ForEach(recent) { item in
                    BarMark(
                        x: .value("Mês", Format.month(item.month)),
                        y: .value("Valor", Double(item.income) / 100)
                    )
                    .foregroundStyle(by: .value("Tipo", "Entradas"))
                    .position(by: .value("Tipo", "Entradas"))

                    BarMark(
                        x: .value("Mês", Format.month(item.month)),
                        y: .value("Valor", Double(item.expense) / 100)
                    )
                    .foregroundStyle(by: .value("Tipo", "Gastos"))
                    .position(by: .value("Tipo", "Gastos"))
                }
            }
            .chartForegroundStyleScale(["Entradas": Color.green, "Gastos": Color.red])
            .frame(height: 220)
        }
        .card()
    }
}

private struct CategoryAmount: Identifiable {
    let category: SpendCategory
    let cents: Int
    var id: String { category.rawValue }
}

private struct StatTile: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Format.brl(value))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct OwnNameCard: View {
    @EnvironmentObject private var store: AppStore
    let candidate: OwnNameCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Esta conta é sua?").font(.headline)
            Text(candidate.name.capitalized).font(.subheadline.weight(.medium))
            Text("\(candidate.count) transferências: \(Format.brl(candidate.inCents)) recebidos e \(Format.brl(candidate.outCents)) enviados. Se for sua, elas deixam de contar como entrada e gasto.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button("Sim, é minha") { store.resolveOwnName(candidate.name, isMine: true) }
                    .buttonStyle(.borderedProminent)
                Button("Não") { store.resolveOwnName(candidate.name, isMine: false) }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

extension View {
    func card() -> some View {
        padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
