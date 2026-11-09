import Foundation

struct CategoryRule: Decodable {
    let field: String?
    let contains: String
    let category: SpendCategory
    let direction: String?
}

struct Categorizer {
    private let rules: [CategoryRule]

    private static let bankMap: [String: SpendCategory] = [
        "casa": .moradia,
        "contas": .contas,
        "educacao": .educacao,
        "alimentacao": .alimentacao,
        "supermercado": .supermercado,
        "saude": .saude,
        "transporte": .transporte,
        "tarifas": .impostos,
        "credito e financiamento": .credito,
        "lazer e entretenimento": .lazer,
        "cuidados pessoais": .cuidados,
        "compras": .compras,
        "reembolso": .reembolso,
        "investimentos": .investimentos,
        "salario": .salario,
        "bonus e plr": .bonus
    ]

    init(bundle: Bundle = .main) {
        if let url = bundle.url(forResource: "rules", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([CategoryRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
    }

    /// O que o banco já disse sobre cada estabelecimento na conta ajuda a classificar a fatura, que não traz categoria.
    func bankLookup(from items: [Lancamento]) -> [String: SpendCategory] {
        var lookup: [String: SpendCategory] = [:]
        for item in items where !item.isCard {
            if let mapped = Self.bankMap[item.bankCategory.folded], mapped.kind == .expense {
                lookup[item.merchantName.folded] = mapped
            }
        }
        return lookup
    }

    func category(for item: Lancamento, user: UserClassification, lookup: [String: SpendCategory] = [:]) -> SpendCategory {
        if let manual = user.overrides[item.id] { return manual }

        if let learned = user.merchantRules[item.merchantRuleKey] { return learned }

        let description = item.description.folded

        let bank = item.bankCategory.folded
        if bank == "investimentos" { return .investimentos }

        let type = item.type.folded
        if (type.contains("pix") || type.contains("transfer")), user.ownNames.contains(description) {
            return .interno
        }

        for rule in rules {
            let haystack = " " + (rule.field == "type" ? type : description)
            guard haystack.contains(" " + rule.contains) else { continue }
            if rule.direction == "out", item.cents >= 0 { continue }
            return rule.category
        }

        if item.isCard {
            if let known = lookup[item.merchantName.folded] { return known }
            return item.cents < 0 ? .outros : .reembolso
        }

        if let mapped = Self.bankMap[bank] { return mapped }
        if bank == "transferencia" { return item.cents < 0 ? .pessoas : .outrasEntradas }
        return item.cents < 0 ? .outros : .outrasEntradas
    }
}
