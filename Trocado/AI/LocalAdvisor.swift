import Foundation
import os
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

struct AdvisorModel: Identifiable, Hashable {
    let id: String
    let name: String
    let downloadSize: String
    let minimumAvailableMB: Int
    let note: String

    static let catalog: [AdvisorModel] = [
        AdvisorModel(
            id: "augible/qwen3.5-2b-4bit-text-mlx",
            name: "Qwen 3.5 2B",
            downloadSize: "cerca de 1,1 GB",
            minimumAvailableMB: 1_700,
            note: "Recomendado. Roda sem ajuste de memória."
        ),
        AdvisorModel(
            id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            name: "Qwen 3 4B",
            downloadSize: "cerca de 2,3 GB",
            minimumAvailableMB: 3_000,
            note: "Respostas melhores, mas fica perto do limite de memória."
        )
    ]
}

@MainActor
final class LocalAdvisor: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case thinking
        case writing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var text = ""
    @Published var selectedModelID: String = AdvisorModel.catalog[0].id

    private var container: ModelContainer?
    private var loadedModelID: String?
    private var task: Task<Void, Never>?

    private static let instructions = """
    Você é um consultor de finanças pessoais no Brasil. Responda em português do Brasil.
    Use somente os números fornecidos e nunca invente valores.
    Não recomende produtos financeiros específicos.
    Escreva uma lista curta. Cada item começa com a ação e cita a categoria e o valor em reais.
    """

    var selectedModel: AdvisorModel {
        AdvisorModel.catalog.first { $0.id == selectedModelID } ?? AdvisorModel.catalog[0]
    }

    var isBusy: Bool {
        switch phase {
        case .downloading, .thinking, .writing: return true
        case .idle, .failed: return false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isBusy { phase = .idle }
    }

    func generate(prompt: String) {
        guard !isBusy else { return }
        let model = selectedModel

        if loadedModelID != model.id {
            let availableMB = Int(os_proc_available_memory() / 1_048_576)
            if availableMB < model.minimumAvailableMB {
                phase = .failed("Há \(availableMB) MB livres para o app e este modelo precisa de \(model.minimumAvailableMB) MB. Feche outros apps ou use o modelo menor.")
                return
            }
        }

        text = ""
        task = Task { [weak self] in
            await self?.run(model: model, prompt: prompt)
        }
    }

    private func run(model: AdvisorModel, prompt: String) async {
        do {
            let loaded = try await loadIfNeeded(model)
            try Task.checkCancellation()
            phase = .thinking

            let session = ChatSession(
                loaded,
                instructions: Self.instructions,
                generateParameters: GenerateParameters(maxTokens: 700, temperature: 0.3)
            )

            var raw = ""
            for try await chunk in session.streamResponse(to: prompt) {
                try Task.checkCancellation()
                raw += chunk
                let visible = Self.removeReasoning(raw)
                if !visible.isEmpty {
                    phase = .writing
                    text = visible
                }
            }
            phase = .idle
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadIfNeeded(_ model: AdvisorModel) async throws -> ModelContainer {
        if let container, loadedModelID == model.id { return container }
        container = nil
        loadedModelID = nil
        phase = .downloading(0)

        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: model.id),
            progressHandler: { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    self?.phase = .downloading(fraction)
                }
            }
        )
        container = loaded
        loadedModelID = model.id
        return loaded
    }

    /// Alguns modelos pensam em voz alta entre <think> e </think>; o usuário só vê a resposta.
    private static func removeReasoning(_ raw: String) -> String {
        var output = raw
        while let open = output.range(of: "<think>") {
            if let close = output.range(of: "</think>", range: open.upperBound..<output.endIndex) {
                output.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                output.removeSubrange(open.lowerBound..<output.endIndex)
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
