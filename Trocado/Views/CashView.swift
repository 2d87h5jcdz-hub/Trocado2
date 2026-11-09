import SwiftUI

struct CashView: View {
    @EnvironmentObject private var store: AppStore
    @State private var until = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var adding = false
    @State private var editing: CashOccurrence?
    @State private var editingBalance = false
    @State private var balanceText = ""

    private var forecast: CashForecast {
        store.forecast(until: Day(date: until))
    }

    var body: some View {
        let data = forecast

        return NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Em caixa").font(.caption).foregroundStyle(.secondary)
                            Text(data.hasBalance ? Format.brl(data.startingCents) : "Sem saldo")
                                .font(.title2.weight(.semibold))
                            Text(data.hasBalance ? "Base em \(data.startingDay.short)" : "Importe um extrato ou informe o saldo")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Ajustar") {
                            balanceText = ""
                            editingBalance = true
                        }
                        .buttonStyle(.bordered)
                    }
                    DatePicker("Ver até", selection: $until, in: Date()..., displayedComponents: .date)
                }

                Section("Até \(Day(date: until).short)") {
                    LabeledContent("A receber", value: Format.brl(data.receivable))
                        .foregroundStyle(.green)
                    LabeledContent("A pagar", value: Format.brl(data.payable))
                        .foregroundStyle(.red)
                    LabeledContent("Previsão de saldo", value: Format.brl(data.finalCents))
                        .font(.headline)
                        .foregroundStyle(data.finalCents < 0 ? Color.red : Color.primary)
                    if let day = data.lowestDay, data.lowestCents < 0 {
                        Label("Faltam \(Format.brl(-data.lowestCents)) em \(day.short)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline.weight(.medium))
                    }
                }

                Section("Próximos movimentos") {
                    if data.occurrences.isEmpty {
                        Text("Nada previsto neste período.").foregroundStyle(.secondary)
                    }
                    ForEach(data.occurrences) { occurrence in
                        Button { editing = occurrence } label: {
                            OccurrenceRow(occurrence: occurrence)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Caixa")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Adicionar conta ou entrada prevista")
                }
            }
            .sheet(isPresented: $adding) {
                CashItemForm()
            }
            .sheet(item: $editing) { occurrence in
                OccurrenceEditor(occurrence: occurrence)
            }
            .alert("Saldo em caixa hoje", isPresented: $editingBalance) {
                TextField("Valor", text: $balanceText)
                    .keyboardType(.numbersAndPunctuation)
                Button("Salvar") {
                    if let cents = signedCents(balanceText) {
                        store.setManualBalance(cents: cents)
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Vale até você importar um extrato mais novo.")
            }
        }
    }

    private func signedCents(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "0" || trimmed == "0,00" { return 0 }
        if trimmed.hasPrefix("-") {
            return Format.cents(fromInput: String(trimmed.dropFirst())).map { -$0 }
        }
        return Format.cents(fromInput: trimmed)
    }
}

private struct OccurrenceRow: View {
    let occurrence: CashOccurrence

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(occurrence.day.short)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(occurrence.name).lineLimit(1)
                Text(occurrence.isOverdue ? "Ainda não apareceu como paga" : occurrence.source.label)
                    .font(.caption)
                    .foregroundStyle(occurrence.isOverdue ? Color.orange : Color.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.brl(occurrence.cents))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(occurrence.cents > 0 ? Color.green : Color.primary)
                Text(Format.brl(occurrence.balanceAfter))
                    .font(.caption)
                    .foregroundStyle(occurrence.balanceAfter < 0 ? Color.red : Color.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct OccurrenceEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let occurrence: CashOccurrence
    @State private var amount = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Previsto", value: Format.brl(abs(occurrence.cents)))
                    LabeledContent("Data", value: occurrence.day.short)
                    LabeledContent("Origem", value: occurrence.source.label)
                }
                Section("Corrigir valor desta vez") {
                    TextField("Novo valor", text: $amount)
                        .keyboardType(.decimalPad)
                    Button("Salvar valor") {
                        if let cents = Format.cents(fromInput: amount) {
                            store.setAmount(cents, for: occurrence)
                            dismiss()
                        }
                    }
                    .disabled(Format.cents(fromInput: amount) == nil)
                }
                Section {
                    Button(occurrence.cents > 0 ? "Já recebi" : "Já paguei") {
                        store.markSettled(occurrence)
                        dismiss()
                    }
                    if occurrence.source != .installment {
                        Button(occurrence.source == .manual ? "Apagar" : "Não prever mais", role: .destructive) {
                            store.stopForecasting(occurrence)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(occurrence.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
    }
}

private struct CashItemForm: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var isIncome = false
    @State private var name = ""
    @State private var amount = ""
    @State private var date = Date()
    @State private var repeats = false

    private var canSave: Bool {
        Format.cents(fromInput: amount) != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Tipo", selection: $isIncome) {
                    Text("A pagar").tag(false)
                    Text("A receber").tag(true)
                }
                .pickerStyle(.segmented)
                TextField("Descrição", text: $name)
                TextField("Valor", text: $amount)
                    .keyboardType(.decimalPad)
                DatePicker(isIncome ? "Recebimento" : "Vencimento", selection: $date, displayedComponents: .date)
                Toggle("Repetir todo mês", isOn: $repeats)
            }
            .navigationTitle(isIncome ? "Entrada prevista" : "Conta a pagar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        if let cents = Format.cents(fromInput: amount) {
                            store.addCashItem(name: name, cents: cents, isIncome: isIncome, day: Day(date: date), repeatsMonthly: repeats)
                            dismiss()
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
