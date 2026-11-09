import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let excelXLS = UTType("com.microsoft.excel.xls") ?? UTType(filenameExtension: "xls") ?? .data
    static let excelXLSX = UTType("org.openxmlformats.spreadsheetml.sheet") ?? UTType(filenameExtension: "xlsx") ?? .data
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showImporter = false

    var body: some View {
        TabView {
            SummaryView(showImporter: $showImporter)
                .tabItem { Label("Resumo", systemImage: "chart.bar") }
            EntriesView()
                .tabItem { Label("Lançamentos", systemImage: "list.bullet") }
            CashView()
                .tabItem { Label("Caixa", systemImage: "banknote") }
            SuggestionsView()
                .tabItem { Label("Sugestões", systemImage: "lightbulb") }
            SettingsView(showImporter: $showImporter)
                .tabItem { Label("Ajustes", systemImage: "gearshape") }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.excelXLS, .excelXLSX]) { result in
            switch result {
            case .success(let url):
                Task { await store.importFile(at: url) }
            case .failure(let error):
                store.importMessage = error.localizedDescription
            }
        }
        .alert(
            "Importação",
            isPresented: Binding(
                get: { store.importMessage != nil },
                set: { if !$0 { store.importMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.importMessage ?? "")
        }
        .background(PasswordPrompt())
        .overlay {
            if store.isImporting {
                ProgressView("Lendo extrato…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

private struct PasswordPrompt: View {
    @EnvironmentObject private var store: AppStore
    @State private var password = ""

    var body: some View {
        Color.clear
            .alert(
                store.lastPasswordWasWrong ? "Senha incorreta" : "Arquivo protegido",
                isPresented: Binding(
                    get: { store.pendingEncryptedFile != nil },
                    set: { if !$0 { store.pendingEncryptedFile = nil } }
                )
            ) {
                SecureField("Senha", text: $password)
                    .keyboardType(.numberPad)
                Button("Abrir") {
                    store.submitPassword(password)
                    password = ""
                }
                Button("Cancelar", role: .cancel) { password = "" }
            } message: {
                Text("Digite a senha da fatura. Ela fica guardada só no Keychain deste iPhone.")
            }
    }
}

struct EmptyImportView: View {
    @Binding var showImporter: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Nenhum extrato ainda", systemImage: "doc.badge.plus")
        } description: {
            Text("Importe o extrato da conta (.xls) e as faturas do cartão BTG (.xlsx). Os dados ficam só neste iPhone.")
        } actions: {
            Button("Importar extrato") { showImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }
}
