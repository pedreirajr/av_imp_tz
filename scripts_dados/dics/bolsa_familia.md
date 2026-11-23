# Dicionário de dados: Bolsa Família Municipal

## Identificação da base

- **Asset publicado:** `bolsa_familia_mensal_municipio.parquet` (release `data`, repositório `pedreirajr/av_imp_tz`)
- **Script produtor:** `scripts_dados/bolsa_familia.R`
- **Fonte primária:** Controladoria-Geral da União (CGU) / Portal da Transparência — Benefícios ao Cidadão, consolidados na Base dos Dados (`basedosdados.br_cgu_beneficios_cidadao`: tabelas `bolsa_familia_pagamento`, `auxilio_brasil` e `novo_bolsa_familia`).
- **Nível de observação:** município × ano × mês × programa.
- **Chave única:** `ano` × `mes` × `code_state` × `code_muni` × `programa`.
- **Período:** janeiro de 2013 (`2013-01`) a abril de 2026 (`2026-04`), totalizando 160 competências mensais contínuas na auditoria de 23/11/2026.
- **Abrangência:** 27 UFs e 5.570 municípios identificados na referência territorial `geobr` 2022 (incluindo Distrito Federal e Fernando de Noronha), totalizando **897.660 linhas** (incluindo 7 linhas sem município identificado em Mato Grosso entre `2025-10` e `2026-04`).

## Composição por programa (auditoria de 23/11/2026)

| `programa` | linhas | competências completas | competências retroativas parciais | soma de `qtd_parcelas` | soma de `valor_total` (R\$ correntes) |
| --- | ---: | --- | --- | ---: | ---: |
| `bolsa_familia` | 595.939 | `2013-01` a `2021-11` (107 meses) | — | 1.495.160.932 | 261.511.315.556,00 |
| `auxilio_brasil` | 90.054 | `2021-11` a `2023-02` (16 meses) | `2020-08` e `2021-03` a `2021-10` (9 meses; 934 linhas) | 293.954.669 | 92.211.446.410,00 |
| `novo_bolsa_familia` | 211.667 | `2023-03` a `2026-04` (38 meses) | — | 754.025.214 | 500.342.677.257,00 |

## Colunas

| nome original na fonte | coluna | tipo | unidade | descrição | valores possíveis e `NA` |
| --- | --- | --- | --- | --- | --- |
| `ano_competencia` | `ano` | `integer` | ano | Ano da competência a que se refere a parcela paga. | Inteiros de `2013` a `2026`. Não tem `NA`. |
| `mes_competencia` | `mes` | `integer` | mês | Mês da competência a que se refere a parcela paga. | Inteiros de `1` a `12`. Não tem `NA`. |
| — (`geobr` / `sigla_uf`) | `code_state` | `integer` | — | Código IBGE da UF (2 dígitos), obtido do `geobr` 2022 a partir de `code_muni` (ou da `sigla_uf` da fonte quando `code_muni` é `NA`). | Códigos IBGE das 27 UFs (`11` a `53`); reserva `99` para UF não identificada. Na auditoria de 23/11/2026 não há linhas com `99`. Não tem `NA`. |
| — (`geobr` / `sigla_uf`) | `abbrev_state` | `character` | — | Sigla da UF, obtida do `geobr` 2022 a partir de `code_muni` (ou da fonte quando `code_muni` é `NA`). | As 27 siglas de UF (`AC` a `TO`); reserva `"NI"` para UF não identificada. Não tem `NA`. |
| `id_municipio` | `code_muni` | `integer` | — | Código IBGE do município (7 dígitos), reconciliado com `geobr` 2022 (`read_municipality` + `lookup_muni`). | 5.570 códigos municipais válidos. `NA` indica pagamento cuja UF é conhecida mas o município não consta mapeado na fonte (7 linhas em MT entre `2025-10` e `2026-04`). |
| — (`geobr`) | `name_muni` | `character` | — | Nome oficial do município obtido exclusivamente do `geobr` 2022. | Nomes oficiais do `geobr`. `NA` exclusivamente quando `code_muni` é `NA` (7 linhas). |
| — (tabela de origem) | `programa` | `character` | — | Identificador do programa federal correspondente à tabela da CGU. | `"bolsa_familia"`, `"auxilio_brasil"` ou `"novo_bolsa_familia"`. Não tem `NA`. |
| `COUNT(DISTINCT nis_favorecido)` | `qtd_beneficiarios` | `integer` | beneficiários (NIS distintos) | Número de beneficiários distintos (NIS únicos) com parcela paga na competência, município e programa. | Inteiro estritamente positivo (`>= 1`). Não tem `NA`. |
| `COUNT(*)` | `qtd_parcelas` | `integer` | parcelas | Quantidade total de parcelas pagas na competência, município e programa. Pode superar `qtd_beneficiarios` quando um mesmo NIS recebe parcela complementar/retroativa no mesmo mês (ocorre em 353.370 linhas). | Inteiro estritamente positivo (`>= qtd_beneficiarios`). Não tem `NA`. |
| `SUM(valor_parcela)` | `valor_total` | `double` | R\$ correntes | Soma nominal dos valores das parcelas pagas na competência, município e programa. Valores não deflacionados. | Número real estritamente positivo (`> 0`). Não tem `NA`. |
| `valor_total / qtd_beneficiarios` | `valor_medio` | `double` | R\$ correntes / beneficiário | Valor médio nominal recebido por beneficiário distinto no município, competência e programa. | Número real estritamente positivo (`> 0`). Não tem `NA`. |

## Regras de interpretação

1. **Não somar `bolsa_familia` e `auxilio_brasil` em novembro de 2021 (`2021-11`) sem tratamento.** Na transição institucional de novembro de 2021, ambas as tabelas da CGU publicaram folhas completas para todos os 5.570 municípios (`bolsa_familia`: 14.506.301 beneficiários e R\$ 3,255 bi; `auxilio_brasil`: 14.355.963 beneficiários e R\$ 3,232 bi). Somar as duas linhas em `2021-11` duplica o mês.
2. **Atenção às 934 linhas retroativas de `auxilio_brasil` anteriores a `2021-11`.** Entre `2020-08` e `2021-10`, há 934 linhas (2.990 parcelas, R\$ 553.869,00) referentes a pagamentos retroativos contabilizados na base do Auxílio Brasil. Para análises de painel mensal contínuo, defina explicitamente se deseja filtrar cada programa apenas em sua vigência principal (`bolsa_familia`: `2013-01` a `2021-10`; `auxilio_brasil`: `2021-11` a `2023-02`; `novo_bolsa_familia`: `2023-03` em diante).
3. **Ausência de linha não equivale a zero.** Entre `2013-01` e `2014-01`, cinco municípios recém-emancipados em 2013 ingressaram gradualmente na base (5.565 a 5.569 municípios); sua ausência indica falta de registro individualizado na fonte, e não zero beneficiários.
4. **Valores em reais correntes.** `valor_total` e `valor_medio` estão em R\$ nominais de cada competência; comparações ao longo de 2013–2026 exigem deflacionamento (por exemplo, via IPCA).
5. **Detalhes metodológicos e lacunas completas** estão documentados em `scripts_dados/docs/bolsa_familia.md`.
