import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var advisor: LocalAdvisor
    @Binding var showImporter: Bool
    @State private var confirmErase = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Dados") {
                    Button("Importar extrato") { showImporter = true }
                    LabeledContent("Lançamentos", value: "\(store.lancamentos.count)")
                }

                Section {
                    Picker("Modelo", selection: $advisor.selectedModelID) {
                        ForEach(AdvisorModel.catalog) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .disabled(advisor.isBusy)
                } header: {
                    Text("IA local")
                } footer: {
                    Text(advisor.selectedModel.note)
                }

                if !store.classification.ownNames.isEmpty {
                    Section("Contas consideradas suas") {
                        ForEach(store.classification.ownNames.sorted(), id: \.self) { name in
                            HStack {
                                Text(name.capitalized)
                                Spacer()
                                Button("Remover") { store.resolveOwnName(name, isMine: false) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                if !store.invoices.isEmpty {
                    Section("Faturas importadas") {
                        ForEach(store.invoices.sorted { $0.dueMonth > $1.dueMonth }, id: \.dueMonth) { invoice in
                            LabeledContent(Format.month(invoice.dueMonth), value: Format.brl(invoice.totalCents))
                        }
                    }
                }

                Section {
                    Button("Apagar todos os dados", role: .destructive) { confirmErase = true }
                }
            }
            .navigationTitle("Ajustes")
            .confirmationDialog("Apagar extratos e classificações?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Apagar", role: .destructive) { store.eraseEverything() }
            }
        }
    }
}
