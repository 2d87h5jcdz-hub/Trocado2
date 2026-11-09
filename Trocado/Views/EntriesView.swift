import SwiftUI

struct EntriesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var search = ""
    @State private var filter: SpendCategory?
    @State private var editing: Lancamento?

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
