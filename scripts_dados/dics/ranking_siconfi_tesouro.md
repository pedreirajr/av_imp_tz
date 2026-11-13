# Dicionário de dados: Ranking Siconfi (Tesouro Nacional)

## Identificação da base

- **Asset publicado:** `ranking_siconfi_municipio.parquet` (release `data`)
- **Fonte:** Secretaria do Tesouro Nacional (STN), Ranking da Qualidade
  da Informação Contábil e Fiscal no Siconfi, arquivo
  `municipios_bspn.zip`.
- **Nível de observação:** município × ano.
- **Chave única:** `code_muni` × `ano`.
- **Período:** 2019 a 2025.
- **Abrangência:** 26 UFs; 5.568 municípios em todos os anos (38.976
  linhas). Não incluem o Distrito Federal (5300108) nem Fernando de
  Noronha (2605459), porque os dois não constam na fonte.

## Colunas

| nome original na fonte | coluna | tipo | unidade | descrição | valores possíveis e `NA` |
|----|----|----|----|----|----|
| `Ente` | `code_muni` | integer | — | Código IBGE do município (7 dígitos), padrão `geobr` | Código existente no `geobr` 2022. Não tem `NA`. |
| — | `name_muni` | character | — | Nome do município, vindo do `geobr` 2022 (não da fonte) | Não tem `NA`. |
| — | `abbrev_state` | character | — | Sigla da UF, vinda do `geobr` | 26 UFs, sem DF. Não tem `NA`. |
| — | `code_state` | integer | — | Código IBGE da UF (2 dígitos), vindo do `geobr` | Não tem `NA`. |
| `exercicio` | `ano` | integer | ano | Exercício de referência das informações avaliadas | 2019 a 2025. Não tem `NA`. |
| `per_acertos` | `per_acertos` | double | proporção (0 a 1) | Pontuação obtida pelo município dividida pela pontuação máxima possível no ano | De 0 a 1. Não tem `NA`. O valor 0 aparece em 42 linhas (ver abaixo). |

## Cuidados com `per_acertos`

- **O denominador muda a cada ano.** A pontuação máxima possível
  (`acertos_total ÷ per_acertos` na fonte) foi 60 em 2019, 87 em 2020,
  91 em 2021, 128 em 2022, 148 em 2023, 171 em 2024 e 195 em 2025. O
  mesmo `per_acertos` em anos diferentes não representa o mesmo
  desempenho. Ver `scripts_dados/docs/ranking_siconfi_tesouro.md`.
- **Zero não é dado ausente.** As 42 linhas com `per_acertos = 0` (a
  partir de 2022) são municípios com todos os itens da avaliação
  zerados na fonte.
