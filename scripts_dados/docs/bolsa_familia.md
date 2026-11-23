# Documentação: Bolsa Família Municipal

## Fonte

- **Instituição primária:** Controladoria-Geral da União (CGU) / Portal da Transparência — Benefícios ao Cidadão (folhas mensais de pagamento do Bolsa Família, Auxílio Brasil e Novo Bolsa Família).
- **Página oficial de dados abertos:** <https://portaldatransparencia.gov.br/download-de-dados/novo-bolsa-familia>
- **Repositório de extração utilizado:** Base dos Dados (`basedosdados.br_cgu_beneficios_cidadao`), catálogo em <https://basedosdados.org/dataset/br-cgu-beneficios-cidadao>:
  - `basedosdados.br_cgu_beneficios_cidadao.bolsa_familia_pagamento`
  - `basedosdados.br_cgu_beneficios_cidadao.auxilio_brasil`
  - `basedosdados.br_cgu_beneficios_cidadao.novo_bolsa_familia`
- **Data da extração e auditoria:** 23/11/2026.

### Escolha da fonte diante da indisponibilidade de `owdbr` e `misocialr`

Antes de adotar a consulta agregada no BigQuery da Base dos Dados (padrão já utilizado em `scripts_dados/frota_denatran.R`), foram testados dois pacotes R voltados a programas sociais:

1. **`owdbr` (`v1.0.1.1`, CRAN, última atualização em nov/2019):** A função `owdbr::getpbf_mun()` consulta `http://www.transparencia.gov.br/api-de-dados/bolsa-familia-por-municipio?` sem cabeçalho de autenticação. Atualmente essa URL redireciona para bloqueio WAF/Captcha (`HTTP 405 Not Allowed`). A API vigente da CGU (`api.portaldatransparencia.gov.br`) exige chave cadastrada via conta Gov.br (`chave-api-dados`), divide a série em três rotas distintas e exige requisições individuais por município e mês (mais de 1 milhão de chamadas HTTP para toda a série nacional).
2. **`misocialr` (`v0.4.0`, CRAN, out/2026):** Consome a API Solr da Matriz de Informação Social do MDS (`https://aplicacoes.mds.gov.br/sagi/servicos/misocial`). Na data da extração (23/11/2026), o servidor `aplicacoes.mds.gov.br` redirecionava todas as chamadas para a página HTML `https://www.gov.br/mds/pt-br/avisos` por manutenção preventiva de segurança.

A Base dos Dados já mantém as folhas mensais oficiais da CGU convertidas do código SIAFI para o código IBGE de 7 dígitos (`id_municipio`), permitindo a agregação mensal por município diretamente no BigQuery dentro da franquia gratuita de 1 TB/mês.

## O que o script faz

Script: `scripts_dados/bolsa_familia.R`.

1. Monta uma consulta Standard SQL que une as três tabelas de pagamento de `basedosdados.br_cgu_beneficios_cidadao` para `ano_competencia >= 2013` e agrega diretamente no BigQuery por `ano`, `mes`, `programa`, `sigla_uf_fonte` e `id_municipio_fonte`, calculando `qtd_beneficiarios` (`COUNT(DISTINCT nis_favorecido)`), `qtd_parcelas` (`COUNT(*)`) e `valor_total` (`SUM(valor_parcela)`).
2. Executa previamente um *dry-run* gratuito (`bigrquery::bq_perform_query_dry_run()`) e impõe trava dupla de volume de leitura (`250 GB`, tanto no cliente quanto via `maximumBytesBilled` no servidor BigQuery). Na conferência de 23/11/2026, `bolsa_familia_pagamento` estimou 69,63 GB, `auxilio_brasil` estimou 13,69 GB e `novo_bolsa_familia` teve a estimativa omitida pelo BigQuery em razão de *Row-Level Security*, permanecendo protegida pela trava server-side de 250 GB. O resumo agregado (~15 MB) é armazenado em cache local fora do repositório (`tools::R_user_dir`) para evitar reconsultas em revalidações (ignorável via `--sem-cache`).
3. Constrói a tabela de referência territorial do `geobr` (2022) unindo `geobr::read_municipality(year = 2022, simplified = TRUE)` e `geobr::lookup_muni(year = 2022, name_muni = "all")` (5.571 unidades, combinando Fernando de Noronha e Boa Esperança do Norte).
4. Padroniza `code_muni` (inteiro de 7 dígitos), `name_muni`, `abbrev_state` e `code_state` exclusivamente a partir do `geobr`, preserva em linha própria registros sem município identificado (`code_muni = NA`, `name_muni = NA`, mantendo a UF conhecida ou `99`/`NI` se desconhecida) e calcula `valor_medio = valor_total / qtd_beneficiarios`.
5. Executa travas rígidas (`validar_bolsa_familia()`): impede saída vazia, chaves duplicadas em `ano × mes × code_state × code_muni × programa`, `NA` em colunas obrigatórias, falhas de continuidade no calendário mensal, códigos IBGE inexistentes ou incompatíveis com a UF, ausência de alguma das 27 UFs, valores não positivos/não finitos e qualquer divergência de soma de `qtd_parcelas` ou `valor_total` contra a consulta bruta.
6. Grava `bolsa_familia_mensal_municipio.parquet` exclusivamente em `tempdir()`. Quando executado com `--publicar`, envia o arquivo para a release `data` via `piggyback::pb_upload(..., overwrite = TRUE)` e remove o arquivo temporário com `unlink()` inclusive em caso de erro no upload.

## Requisitos

- Pacotes R: `bigrquery`, `dplyr`, `geobr`, `sf`, `arrow`, `jsonlite` (e `piggyback`, `gh`, `httr` para `--publicar`; `testthat` e `bit64` para a suíte de testes).
- Projeto Google Cloud com API do BigQuery habilitada (funciona no BigQuery Sandbox gratuito sem cartão de crédito, com cota de 1 TB/mês). Definir `BILLING_ID=<id-do-projeto>` no arquivo `.Renviron` na raiz do repositório (nunca versionado) e autenticar a conta Google uma vez via `bigrquery::bq_auth()`.
- Para publicar na release (`--publicar`), token do GitHub com permissão de escrita em `GITHUB_PAT` ou configurado via `gitcreds`.

Execução a partir da raiz do repositório:

```bash
Rscript scripts_dados/bolsa_familia.R
Rscript scripts_dados/bolsa_familia.R --publicar
Rscript scripts_dados/tests/test_bolsa_familia.R
```

## Problemas, lacunas e cuidados

- **Início efetivo em janeiro de 2013 (`2013-01`) e exclusão de retroativos de 2012.** Embora o recorte padrão do projeto seja 2010, as folhas mensais de pagamento da CGU disponíveis na Base dos Dados começam em janeiro de 2013. Na tabela `bolsa_familia_pagamento`, existem 15.079 linhas com `ano_competencia = 2012` (`2012-02` a `2012-12`, totalizando 62.664 parcelas e R\$ 7.553.598,00), referentes apenas a parcelas retroativas pagas nas folhas de 2013 (cobrindo de 82 municípios em fev/2012 a 3.936 em dez/2012). Essas linhas parciais foram excluídas pelo corte `ano >= 2013` para evitar a falsa impressão de cobertura completa em 2012.

- **Sobreposição em novembro de 2021 (`2021-11`) na transição para o Auxílio Brasil.** Novembro de 2021 é o mês de migração do Programa Bolsa Família para o Auxílio Brasil (Lei nº 14.284/2021), e ambas as tabelas da CGU publicam folhas completas para todos os 5.570 municípios nessa competência:

  | `programa` em `2021-11` | municípios | `qtd_beneficiarios` | `qtd_parcelas` | `valor_total` (R\$) |
  | --- | ---: | ---: | ---: | ---: |
  | `bolsa_familia` | 5.570 | 14.506.301 | 14.506.301 | 3.254.964.339,00 |
  | `auxilio_brasil` | 5.570 | 14.355.963 | 14.356.059 | 3.231.745.900,00 |

  **Nunca some `bolsa_familia` e `auxilio_brasil` em `2021-11`**: isso dobraria o volume do mês. Para séries contínuas de um registro por município-mês, selecione um único programa em `2021-11` (por exemplo, mantendo `bolsa_familia` até `2021-10` e `auxilio_brasil` a partir de `2021-11`).

- **Quebras institucionais entre programas e 934 linhas retroativas em `auxilio_brasil`.** O desenho de elegibilidade e os valores dos benefícios mudaram substancialmente nas transições para o Auxílio Brasil (`2021-11` a `2023-02`, piso de R\$ 400 e depois R\$ 600) e para o Novo Bolsa Família (`2023-03` em diante, Lei nº 14.601/2023, piso de R\$ 600 com adicionais por criança/gestante). Além disso, a tabela `auxilio_brasil` contém 934 linhas retroativas em competências anteriores a novembro de 2021 (`2020-08` e `2021-03` a `2021-10`, somando 2.990 parcelas e R\$ 553.869,00). Elas foram preservadas para manter o fechamento contábil exato com a fonte, identificadas por `programa = "auxilio_brasil"`.

- **Limite temporal em abril de 2026 (`2026-04`) por *Row-Level Security* da Base dos Dados.** Embora o catálogo da Base dos Dados registre atualização até `2026-10` em `novo_bolsa_familia`, os seis meses mais recentes (`2026-05` a `2026-10`) são restritos à assinatura Base dos Dados Pro via *Row-Level Security* no BigQuery. Na camada pública gratuita, a série cobre de forma contínua todas as **160 competências** de `2013-01` a `2026-04` (sem nenhum mês faltante).

- **7 linhas sem município identificado em Mato Grosso (`2025-10` a `2026-04`).** Na tabela `novo_bolsa_familia`, aparecem 7 registros com `sigla_uf = "MT"` e `id_municipio = NA`, somando 488 parcelas e R\$ 328.416,00 (com crescimento contínuo de 8 beneficiários em `2025-10` para 103 em `2026-04`). Trata-se do município recém-instalado de Boa Esperança do Norte (MT), cujo código SIAFI ainda não estava associado ao código IBGE (`5101837`) na base tratada da CGU. As linhas foram preservadas com `code_state = 51`, `abbrev_state = "MT"`, `code_muni = NA` e `name_muni = NA` para garantir fechamento exato dos totais de Mato Grosso e do Brasil.

- **Cinco municípios emancipados em 2013–2014.** Entre `2013-01` e `2013-09`, constam 5.565 municípios por mês; em `2013-10`, 5.567; e entre `2013-11` e `2014-01`, 5.569. Os cinco municípios ausentes em `2013-01` são os instalados em 2013: Mojuí dos Campos (PA, `1504752`), Pescaria Brava (SC, `4212650`), Balneário Rincão (SC, `4220000`), Pinto Bandeira (RS, `4314548`) e Paraíso das Águas (MS, `5006275`). A partir de `2014-02`, todos os 5.570 municípios identificados aparecem mensalmente.

- **Fernando de Noronha (`2605459`) e referência `geobr` 2022.** Na versão 2022 do `geobr`, `lookup_muni(year = 2022)` omite Fernando de Noronha (`2605459`), que possui 161 linhas na base do Bolsa Família, enquanto `read_municipality(year = 2022)` inclui Fernando de Noronha e omite Boa Esperança do Norte (`5101837`). O script combina ambas as tabelas do `geobr` 2022 (5.571 unidades) para padronizar nomes e códigos sem descartar nenhum registro.

- **Múltiplas parcelas por beneficiário (`qtd_parcelas > qtd_beneficiarios`).** Em 353.370 das 897.660 linhas, o total de parcelas pagas supera o número de NIS distintos no município e competência (quando um mesmo beneficiário recebe parcela complementar ou retroativa no mesmo mês). Em nenhuma linha `qtd_parcelas` é menor que `qtd_beneficiarios`.

- **Valores nominais.** Os campos `valor_total` e `valor_medio` estão em reais correntes, sem correção inflacionária.
