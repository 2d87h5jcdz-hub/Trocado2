# Trocado

App iOS para controlar entradas e gastos a partir do extrato de conta corrente do BTG em `.xls`.
Tudo fica no iPhone. A única conexão de rede é o download do modelo de IA, feito uma vez.

## Gerar o .ipa sem Mac

1. Suba esta pasta para um repositório no GitHub.
2. O workflow **Gerar IPA** roda a cada push em `main` (ou manualmente, na aba Actions).
3. Baixe o artefato `Trocado-ipa` e instale pelo SideStore.

## Como funciona

- `Import/`: leitores de `.xls` (OLE2 + BIFF8) e `.xlsx` protegido por senha (OOXML Agile), escritos em Swift, sem dependências.
- Faturas do cartão: cada compra entra no mês do pagamento da fatura, e o pagamento correspondente na conta deixa de contar, para não duplicar.
- `Resources/rules.json`: regras de categoria por palavra. Têm prioridade sobre a categoria do banco.
- `Engine/InsightEngine.swift`: toda a matemática das sugestões, em código determinístico.
- `AI/LocalAdvisor.swift`: a IA (MLX Swift) só redige o plano a partir dos números já calculados.

A ordem de classificação é: correção manual, regra aprendida, contas próprias, `rules.json`, categoria do banco (na fatura, o que o banco já informou sobre aquele estabelecimento na conta).

## Modelos

| Modelo | Download | Observação |
|---|---|---|
| Qwen 3.5 2B (padrão) | cerca de 1,1 GB | Cabe no limite de memória padrão |
| Qwen 3 4B | cerca de 2,3 GB | Pode exigir o limite de memória ampliado |

Ambos têm licença Apache 2.0. A lista fica em `AdvisorModel.catalog`.

**Nunca coloque extratos reais no repositório.** O `.gitignore` já bloqueia `.xls`, `.xlsx` e `.csv`.
