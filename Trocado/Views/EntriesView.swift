import SwiftUI

struct EntriesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var search = ""
    @State private var filter: SpendCategory?
    @State private var editing: Lancamento?
    @State private var addingManual = false

    private var visible: [Lancamento] {
        let query = search.folded
        return store.lancamentos.filter { item in
            if let filter, store.category(of: item) != filter { return false }
            if query.isEmpty { return true }
            return item.description.folded.contains(query) || item.type.folded.contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(visible) { item in
                Button { editing = item } label: {
                    EntryRow(item: item, category: store.category(of: item))
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Buscar")
            .navigationTitle("Lançamentos")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { addingManual = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Adicionar lançamento manual")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Todas") { filter = nil }
                        ForEach(SpendCategory.allCases) { category in
                            Button(category.title) { filter = category }
                        }
                    } label: {
                        Image(systemName: filter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filtrar por categoria")
                }
            }
            .sheet(item: $editing) { item in
                CategoryPicker(item: item)
            }
            .sheet(isPresented: $addingManual) {
                ManualEntryForm()
            }
        }
    }
}

private struct EntryRow: View {
    let item: Lancamento
    let category: SpendCategory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.symbol)
                .foregroundStyle(category.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.description).lineLimit(1)
                Text("\(item.shortDate) · \(category.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.brl(item.cents))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(item.cents > 0 ? Color.green : Color.primary)
        }
        .contentShape(Rectangle())
    }
}

private struct CategoryPicker: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let item: Lancamento
    @State private var applyToAll = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Valor", value: Format.brl(item.cents))
                    LabeledContent("Tipo", value: item.type)
                    if !item.bankCategory.isEmpty {
                        LabeledContent("Categoria do banco", value: item.bankCategory)
                    }
                    Toggle("Usar sempre nas \(item.cents < 0 ? "saídas para" : "entradas de") “\(item.description)”", isOn: $applyToAll)
                }
                Section("Categoria") {
                    ForEach(SpendCategory.allCases) { category in
                        Button {
                            store.setCategory(category, for: item, applyToAll: applyToAll)
                            dismiss()
                        } label: {
                            HStack {
                                Label(category.title, systemImage: category.symbol)
                                Spacer()
                                if store.category(of: item) == category {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                if item.isManual {
                    Section {
                        Button("Apagar este lançamento", role: .destructive) {
                            store.deleteManualEntry(item, includingInstallments: false)
                            dismiss()
                        }
                        if item.installment != nil {
                            Button("Apagar todas as parcelas", role: .destructive) {
                                store.deleteManualEntry(item, includingInstallments: true)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle(item.description)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
    }
}

private struct ManualEntryForm: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var isExpense = true
    @State private var name = ""
    @State private var amount = ""
    @State private var date = Date()
    @State private var category: SpendCategory = .outros
    @State private var installments = 1

    private var options: [SpendCategory] {
        SpendCategory.allCases.filter { $0.kind == (isExpense ? .expense : .income) }
    }

    private var cents: Int? {
        Format.cents(fromInput: amount)
    }

    private var canSave: Bool {
        cents != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Tipo", selection: $isExpense) {
                        Text("Gasto").tag(true)
                        Text("Entrada").tag(false)
                    }
                    .pickerStyle(.segmented)
                    TextField("Descrição", text: $name)
                    TextField(installments > 1 ? "Valor de cada parcela" : "Valor", text: $amount)
                        .keyboardType(.decimalPad)
                    DatePicker("Data", selection: $date, displayedComponents: .date)
                    Picker("Categoria", selection: $category) {
                        ForEach(options) { option in
                            Text(option.title).tag(option)
                        }
                    }
                }
                if isExpense {
                    Section {
                        Stepper(installments > 1 ? "\(installments) parcelas" : "À vista", value: $installments, in: 1...36)
                    } footer: {
                        if installments > 1, let cents {
                            Text("Total de \(Format.brl(cents * installments)), uma parcela por mês a partir da data escolhida.")
                        }
                    }
                }
            }
            .navigationTitle("Novo lançamento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        guard let cents else { return }
                        store.addManualEntry(
                            description: name,
                            cents: cents,
                            date: date,
                            category: category,
                            installments: isExpense ? installments : 1
                        )
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: isExpense) { _, expense in
                category = expense ? .outros : .outrasEntradas
                if !expense { installments = 1 }
            }
        }
    }
}
