import SwiftUI

struct SuggestionsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var advisor: LocalAdvisor

    var body: some View {
        NavigationStack {
            List {
                if store.insights.isEmpty {
                    Text("Importe um extrato para ver sugestões.")
                        .foregroundStyle(.secondary)
                } else {
                    Section("Calculado a partir do seu extrato") {
                        ForEach(store.insights) { insight in
                            InsightRow(insight: insight)
                        }
                    }
                    advisorSection
                }
            }
            .navigationTitle("Sugestões")
        }
    }

    @ViewBuilder
    private var advisorSection: some View {
        Section {
            switch advisor.phase {
            case .idle:
                Button(advisor.text.isEmpty ? "Gerar plano com IA local" : "Gerar de novo") {
                    advisor.generate(prompt: store.advisorPrompt)
                }
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Baixando \(advisor.selectedModel.name)…")
                    ProgressView(value: fraction)
                    Button("Cancelar", role: .cancel) { advisor.cancel() }
                }
            case .thinking:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Analisando seus números…")
                }
            case .writing:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Escrevendo…")
                }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                Button("Tentar de novo") {
                    advisor.generate(prompt: store.advisorPrompt)
                }
            }

            if !advisor.text.isEmpty {
                Text(advisor.text)
                    .textSelection(.enabled)
            }
        } header: {
            Text("IA local")
        } footer: {
            Text("\(advisor.selectedModel.name), \(advisor.selectedModel.downloadSize). Só o modelo é baixado da internet; seus dados não saem do iPhone. Texto gerado por IA pode errar: os números acima são a referência.")
        }
    }
}

private struct InsightRow: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.symbol)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title).font(.subheadline.weight(.semibold))
                Text(insight.detail).font(.footnote).foregroundStyle(.secondary)
                if let saving = insight.monthlySaving {
                    Text("Potencial: \(Format.brl(saving)) por mês")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
