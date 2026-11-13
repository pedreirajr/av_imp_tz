# Documentação: Ranking Siconfi (Tesouro Nacional)

## Fonte

- **Instituição:** Secretaria do Tesouro Nacional (STN).
- **Base:** Ranking da Qualidade da Informação Contábil e Fiscal no
  Siconfi, municípios.
- **Página:** <https://ranking-municipios.tesouro.gov.br/>
- **Arquivo baixado:**
  <https://ranking-municipios.tesouro.gov.br/static/data/down_loads/municipios_bspn.zip>
  (contém `municipios_bspn_base.csv`).
- **Data da extração:** 13/11/2026. O CSV dentro do zip tem data de
  17/06/2026 e traz os exercícios de 2019 a 2025.

O ranking avalia a qualidade das informações contábeis e fiscais que
cada ente envia ao Siconfi. Cada verificação vale até 1 ponto (há
pontuações parciais, como 0,5). A fonte traz as notas de cada item
(colunas `D1_*` a `D4_*`), os subtotais das quatro dimensões (`DI` a
`DIV`), o total (`acertos_total`), a proporção de acertos
(`per_acertos`), a faixa (`nota_ranking`, de A a E) e a posição
(`class_ranking`). Esta base guarda apenas `per_acertos`.

## O que o script faz

Script: `scripts_dados/ranking_siconfi_tesouro.R`.

1. Baixa o zip para `tempdir()`, com até 5 tentativas, e extrai o CSV.
2. Lê só `exercicio`, `Ente` e `per_acertos` (CSV em UTF-8, separado
   por `;`, com vírgula decimal).
3. Converte `Ente` para `code_muni` (inteiro) e `exercicio` para `ano`,
   e remove linhas repetidas.
4. Confere se todos os códigos existem no `geobr` 2022. Se algum não
   existir, o script para.
5. Acrescenta `name_muni`, `abbrev_state` e `code_state` do `geobr`.
6. Confere se a tabela não está vazia, se não há duplicatas em
   `code_muni` × `ano`, se não há `NA` nos identificadores, se
   `per_acertos` está entre 0 e 1, se nenhuma linha se perdeu no join,
   se as 26 UFs estão presentes e se 2019 está presente.
7. Grava `ranking_siconfi_municipio.parquet` no `tempdir()`, publica o
   arquivo na release `data` com `pb_upload()` e apaga os temporários.

## Requisitos

- Pacotes R: `dplyr`, `readr`, `httr`, `geobr`, `sf`, `arrow` e
  `piggyback`.
- Token do GitHub com permissão de escrita no repositório, em
  `GITHUB_PAT` (no `.Renviron`) ou configurado com o `gitcreds`.

## Problemas, lacunas e cuidados

- **O denominador muda a cada ano.** O número de verificações cresceu
  ao longo do tempo. A pontuação máxima possível, obtida por
  `acertos_total ÷ per_acertos`, foi:

  | ano | pontuação máxima |
  |----|----|
  | 2019 | 60 |
  | 2020 | 87 |
  | 2021 | 91 |
  | 2022 | 128 |
  | 2023 | 148 |
  | 2024 | 171 |
  | 2025 | 195 |

  Um município com o mesmo `per_acertos` em 2019 e em 2025 foi avaliado
  em critérios diferentes. Por isso, ler a variação de `per_acertos` ao
  longo dos anos como melhora ou piora do município pode levar a
  conclusões erradas. Para comparar anos, é mais seguro usar a posição
  relativa dentro de cada ano (por exemplo, o percentil).

- **42 zeros a partir de 2022.** São municípios com todos os itens da
  avaliação zerados na fonte (`acertos_total = 0`, nota E, empatados na
  última posição). Foram 13 em 2022, 9 em 2023, 9 em 2024 e 11 em 2025.
  Oito municípios aparecem zerados em mais de um ano, e Frutuoso Gomes
  (RN, 2404002) aparece zerado nos quatro. Os zeros foram mantidos
  como estão na fonte. O mais provável é que indiquem informações não
  enviadas ou não avaliáveis, e não uma nota baixa em informações
  enviadas. Vale considerar esses casos à parte na análise.

- **Municípios ausentes.** Distrito Federal (5300108) e Fernando de
  Noronha (2605459) não constam na fonte, por isso a base tem 5.568
  municípios por ano, e não os 5.570 do `geobr`.

- **Nomes.** `name_muni` vem do `geobr` 2022, e não da fonte. Os nomes
  da fonte vêm no formato "Município - UF" e usam grafias próprias (por
  exemplo, "Alta Floresta D'Oeste").

- **Sem duplicatas nem `NA`.** A fonte não tem duplicatas em
  `exercicio` × `Ente` nem `per_acertos` vazio.
