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

1. Monta uma consulta Standard SQL que une as três tabelas de pagamento de `basedosdados.br_cgu_beneficios_cidadao` para `ano_competencia >= 2013`, exclui as linhas duplicadas de `bolsa_familia` em `2021-11` e agrega diretamente no BigQuery por `ano`, `mes`, `programa`, `sigla_uf_fonte` e `id_municipio_fonte`, calculando `qtd_familias` (`COUNT(DISTINCT nis_favorecido)`, correspondente aos NIS dos titulares das famílias), `qtd_parcelas` (`COUNT(*)`) e `valor_total` (`SUM(valor_parcela)`).
2. Consulta sempre o BigQuery por padrão. Antes da consulta real, executa um *dry-run* gratuito (`bigrquery::bq_perform_query_dry_run()`) e impõe trava dupla de volume de leitura (`250 GB`, tanto no cliente quanto via `maximumBytesBilled` no servidor BigQuery). Na conferência de 23/11/2026, `bolsa_familia_pagamento` estimou 69,63 GB, `auxilio_brasil` estimou 13,69 GB e `novo_bolsa_familia` teve a estimativa omitida pelo BigQuery em razão de *Row-Level Security*, permanecendo protegida pela trava server-side de 250 GB. O resumo agregado (~15 MB) é salvo em cache local fora do repositório (`tools::R_user_dir`), mas o cache só é reutilizado quando a flag `--usar-cache` é informada explicitamente.
3. Constrói a tabela de referência territorial do `geobr` (2022) unindo `geobr::read_municipality(year = 2022, simplified = TRUE)` e `geobr::lookup_muni(year = 2022, name_muni = "all")` (5.571 unidades, combinando Fernando de Noronha e Boa Esperança do Norte).
4. Padroniza `code_muni` (inteiro de 7 dígitos), `name_muni`, `abbrev_state` e `code_state` exclusivamente a partir do `geobr`, preserva em linha própria registros sem município identificado (`code_muni = NA`, `name_muni = NA`, mantendo a UF conhecida ou `99`/`NI` se desconhecida) e calcula `valor_medio = valor_total / qtd_familias`.
5. Executa travas rígidas (`validar_bolsa_familia()`): impede saída vazia, chaves duplicadas em `ano × mes × code_state × code_muni × programa`, presença de `bolsa_familia` em `2021-11`, `NA` em colunas obrigatórias, falhas de continuidade no calendário mensal, códigos IBGE inexistentes ou incompatíveis com a UF, ausência de alguma das 27 UFs, valores não positivos/não finitos e qualquer divergência de soma de `qtd_parcelas` ou `valor_total` contra a consulta bruta.
6. Grava `bolsa_familia_mensal_municipio.parquet` exclusivamente em `tempdir()`. Quando executado com `--publicar`, envia o arquivo para a release `data` via `piggyback::pb_upload(..., overwrite = TRUE)` e remove o arquivo temporário com `unlink()` inclusive em caso de erro no upload.

## Requisitos

- Pacotes R: `bigrquery`, `dplyr`, `geobr`, `sf`, `arrow`, `jsonlite` (e `piggyback`, `gh`, `httr` para `--publicar`; `testthat` e `bit64` para a suíte de testes).
- Projeto Google Cloud com API do BigQuery habilitada (funciona no BigQuery Sandbox gratuito sem cartão de crédito, com cota de 1 TB/mês). Definir `BILLING_ID=<id-do-projeto>` no arquivo `.Renviron` na raiz do repositório (nunca versionado) e autenticar a conta Google uma vez via `bigrquery::bq_auth()`.
- Para publicar na release (`--publicar`), token do GitHub com permissão de escrita em `GITHUB_PAT` ou configurado via `gitcreds`.

Execução a partir da raiz do repositório:

```bash
Rscript scripts_dados/bolsa_familia.R
Rscript scripts_dados/bolsa_familia.R --publicar
Rscript scripts_dados/bolsa_familia.R --usar-cache
Rscript scripts_dados/tests/test_bolsa_familia.R
```

## Conferência externa contra totais oficiais do MDS

Os totais nacionais agregados do Parquet foram comparados com as séries oficiais do MDS publicadas no Ipeadata (`VAL_PBF12` — valor mensal nacional; `FAM_PBF` e `VAL_PBF` — posição nacional de dezembro) e com comunicados oficiais do Ministério da Cidadania (para os meses de vigência do Benefício Extraordinário do Auxílio Brasil):

| Competência | `programa` | `qtd_familias` (Parquet) | Famílias MDS (`FAM_PBF`) | Dif. famílias | `valor_total` (R\$ bi) | Valor MDS (`VAL_PBF12`, R\$ bi) | Dif. valor | `valor_medio` (R\$) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `2015-12` | `bolsa_familia` | 13.972.235 | 13.980.491 | −0,06% | 2,271 | 2,271 | +0,01% | 162,53 |
| `2019-12` | `bolsa_familia` | 13.205.604 | 13.238.457 | −0,25% | 2,523 | 2,526 | −0,12% | 191,03 |
| `2021-10` | `bolsa_familia` | 14.655.234 | — | — | 2,724 | 2,724 | 0,00% | 185,89 |
| `2021-11` | `auxilio_brasil` | 14.355.963 | — | — | 3,232 | 3,232 | 0,00% | 225,12 |
| `2021-12` | `auxilio_brasil` | 14.186.260 | 14.184.940 | +0,01% | 3,191 | 3,191 | +0,01% | 224,97 |
| `2022-06` | `auxilio_brasil` | 17.410.263 | — | — | 3,675 | 3,680 | −0,15% | 211,06 |
| `2022-07` | `auxilio_brasil` | 17.243.065 | — | — | 7,053 | 7,030 | +0,33% | 409,06 |
| `2022-08` | `auxilio_brasil` | 19.434.595 | — | — | 7,930 | 7,898 | +0,41% | 408,01 |
| `2022-12` | `auxilio_brasil` | 21.329.243 | 20.975.152 | +1,69% | 8,123 | 7,990 | +1,66% | 380,82 |
| `2023-03` | `novo_bolsa_familia` | 20.406.618 | — | — | 13,159 | 13,159 | 0,00% | 644,85 |
| `2024-12` | `novo_bolsa_familia` | 20.548.777 | 20.444.419 | +0,51% | 13,951 | 13,951 | 0,00% | 678,91 |
| `2025-12` | `novo_bolsa_familia` | 18.380.458 | 18.618.236 | −1,28% | 12,459 | 12,613 | −1,22% | 677,84 |

As pequenas diferenças residuais (< 1,7%) decorrem da diferença entre agregação por competência da parcela (`ano_competencia`/`mes_competencia`) versus fechamento por folha de pagamento (`ano_referencia`/`mes_referencia`). Já os valores de `2021-12` a `2023-02` têm uma limitação estrutural importante detalhada abaixo.

## Problemas, lacunas e cuidados

- **Valores subestimados no Auxílio Brasil (`2021-12` a `2023-02`) — ausência do Benefício Extraordinário e descontos do consignado.** Embora `valor_total` no Parquet concorde quase exatamente com a série mensal `VAL_PBF12` do Ipeadata/MDS nesse intervalo (diferenças entre −1,74% e +1,66%), ambas as fontes refletem apenas a **folha regular do Auxílio Brasil** e **não incluem o Benefício Extraordinário**, pago por rubrica/crédito extraordinário separado (não existe tabela separada do Benefício Extraordinário na Base dos Dados, a API do MDS está em manutenção e o download em lote `auxilio-brasil` da CGU retornou `HTTP 403`):
  1. **`2021-12` a `2022-06` (média entre R\$ 211,06 e R\$ 224,97; total entre R\$ 3,19 bi e R\$ 3,87 bi):** o complemento criado pela MP nº 1.076/2021 para garantir o piso de R\$ 400 não entra no campo `valor_parcela` da folha regular.
  2. **Salto em `2022-07` (média sobe de R\$ 211,06 em jun/2022 para R\$ 409,06 em jul/2022; total sobe de R\$ 3,68 bi para R\$ 7,05 bi):** com a conversão na Lei nº 14.342/2022, o piso de R\$ 400 tornou-se permanente e foi incorporado à folha regular a partir de julho de 2022.
  3. **`2022-08` a `2023-02` (média de R\$ 407–408 em ago–out/2022 e ~R\$ 380 em nov/2022–fev/2023):** o adicional temporário de R\$ 200 instituído pela EC nº 123/2022 / MP nº 1.130/2022 (ago–dez/2022) e prorrogado pela MP nº 1.155/2023 (jan–fev/2023) para elevar o piso a R\$ 600 também ficou fora da folha regular. Para comparação, os balanços do Ministério da Cidadania somando o complemento extraordinário informaram **mais de R\$ 12,1 bilhões** (média de R\$ 607,88) em agosto de 2022 (contra R\$ 7,93 bi no Parquet) e cerca de **R\$ 13 bilhões** em dezembro de 2022 (contra R\$ 8,12 bi no Parquet).
  4. **Queda em `2022-11` (de R\$ 407,47 em out/2022 para R\$ 380,28 em nov/2022, mantendo-se em ~R\$ 380 até fev/2023):** coincide com o início dos descontos diretos em folha do **empréstimo consignado do Auxílio Brasil** (Portaria MC nº 816/2022), abatendo a parcela líquida registrada em `valor_parcela`.
  5. Em **`2023-03`** (`novo_bolsa_familia`, Lei nº 14.601/2023), o piso de R\$ 600 e os adicionais por composição familiar passaram a integrar a folha única regular (R\$ 13,159 bi, média R\$ 644,85, fechando 0,00% com o MDS).
  - **Recomendação analítica:** não comparar diretamente `valor_total` ou `valor_medio` de `2021-12` a `2023-02` com `bolsa_familia` ou `novo_bolsa_familia`. A coluna `qtd_familias`, por outro lado, acompanha os totais oficiais do MDS ao longo de toda a série (2013–2026).

- **Remoção das linhas de `bolsa_familia` em novembro de 2021 (`2021-11`).** Na base bruta da CGU, `2021-11` aparece simultaneamente em `bolsa_familia_pagamento` (5.570 municípios; 14.506.301 famílias; R\$ 3.254.964.339,00; média de **R\$ 224,38**) e em `auxilio_brasil` (5.570 municípios; 14.355.963 famílias; R\$ 3.231.745.900,00; média de **R\$ 225,12**). Como a média do `bolsa_familia` entre janeiro e outubro de 2021 era de **R\$ 186,66** (média mensal entre R\$ 185,88 e R\$ 190,57), o salto para R\$ 224,38 em `2021-11` e o fechamento exato de `auxilio_brasil` com o total MDS de `2021-11` (R\$ 3,232 bi, 0,00% de diferença) mostram que as linhas de `bolsa_familia` em `2021-11` reproduzem a primeira folha do Auxílio Brasil. Por isso, o script remove essas 5.570 linhas de `bolsa_familia` em `2021-11`, mantendo apenas `auxilio_brasil` nessa competência.

- **Definição de `ano` e `mes` (competência da parcela × mês da folha) e 934 linhas retroativas de `auxilio_brasil`.** Nas tabelas da CGU na Base dos Dados existem duas datas: `ano_referencia`/`mes_referencia` (mês em que a folha de pagamento foi processada) e `ano_competencia`/`mes_competencia` (mês a que se refere o direito da parcela). Este pipeline utiliza **`ano_competencia` e `mes_competencia`** em `ano` e `mes`, atribuindo cada pagamento ao mês de referência do benefício (o que é mais adequado ao cruzamento com a data de implementação de políticas municipais como a Tarifa Zero). Como consequência, a tabela `auxilio_brasil` traz 934 linhas (2.990 parcelas, R\$ 553.869,00) com competência anterior a novembro de 2021 (`2020-08` e `2021-03` a `2021-10`), correspondentes a parcelas retroativas de competências anteriores pagas em folhas posteriores do Auxílio Brasil. Elas foram preservadas para manter o fechamento contábil exato com a fonte; análises que exijam uma única linha por município × mês podem filtrar `auxilio_brasil` para `ano * 100 + mes >= 202111`.

- **Início efetivo em janeiro de 2013 (`2013-01`) e exclusão de retroativos de 2012.** Embora o recorte padrão do projeto seja 2010, as folhas mensais da CGU na Base dos Dados começam em janeiro de 2013. Na tabela `bolsa_familia_pagamento`, existem 15.079 linhas com `ano_competencia = 2012` (`2012-02` a `2012-12`, totalizando 62.664 parcelas e R\$ 7.553.598,00), referentes apenas a parcelas retroativas pagas nas folhas de 2013 (cobrindo de 82 municípios em fev/2012 a 3.936 em dez/2012). Essas linhas parciais foram excluídas pelo corte `ano >= 2013`.

- **Limite temporal em abril de 2026 (`2026-04`) por *Row-Level Security* da Base dos Dados.** Embora o catálogo da Base dos Dados registre atualização até `2026-10` em `novo_bolsa_familia`, os seis meses mais recentes (`2026-05` a `2026-10`) são restritos à assinatura Base dos Dados Pro via *Row-Level Security* no BigQuery. Na camada pública gratuita, a série cobre de forma contínua todas as **160 competências** de `2013-01` a `2026-04` (sem nenhum mês faltante).

- **7 linhas sem município identificado em Mato Grosso (`2025-10` a `2026-04`).** Na tabela `novo_bolsa_familia`, aparecem 7 registros com `sigla_uf = "MT"` e `id_municipio = NA`, somando 488 parcelas e R\$ 328.416,00, com crescimento contínuo de famílias (`8` em `2025-10`, `24` em `2025-11`, `77` em `2025-12`, `87` em `2026-01`, `93` em `2026-02`, `96` em `2026-03` e `103` em `2026-04`). **Hipótese:** esses registros provavelmente se referem ao município recém-instalado de Boa Esperança do Norte (MT, `5101837`), emancipado e instalado em 2025, cujo código SIAFI pode ainda não estar mapeado para o código IBGE na tabela tratada da Base dos Dados — hipótese baseada na UF (`MT`), no surgimento apenas no final de 2025 e na trajetória crescente compatível com um município novo em fase de transferência cadastral, mas sem confirmação direta no código SIAFI bruto. As 7 linhas foram preservadas com `code_state = 51`, `abbrev_state = "MT"`, `code_muni = NA` e `name_muni = NA` para garantir fechamento exato dos totais de Mato Grosso e do Brasil.

- **Cinco municípios emancipados em 2013–2014.** Entre `2013-01` e `2013-09`, constam 5.565 municípios por mês; em `2013-10`, 5.567; e entre `2013-11` e `2014-01`, 5.569. Os cinco municípios ausentes em `2013-01` são os instalados em 2013: Mojuí dos Campos (PA, `1504752`), Pescaria Brava (SC, `4212650`), Balneário Rincão (SC, `4220000`), Pinto Bandeira (RS, `4314548`) e Paraíso das Águas (MS, `5006275`). A partir de `2014-02`, todos os 5.570 municípios identificados aparecem mensalmente.

- **Fernando de Noronha (`2605459`) e referência `geobr` 2022.** Na versão 2022 do `geobr`, `lookup_muni(year = 2022)` omite Fernando de Noronha (`2605459`), que possui 160 linhas na base final do Bolsa Família, enquanto `read_municipality(year = 2022)` inclui Fernando de Noronha e omite Boa Esperança do Norte (`5101837`). O script combina ambas as tabelas do `geobr` 2022 (5.571 unidades) para padronizar nomes e códigos sem descartar nenhum registro.

- **Múltiplas parcelas por família (`qtd_parcelas > qtd_familias`).** Em 353.370 das 892.090 linhas, o total de parcelas pagas supera o número de NIS distintos de titulares no município e competência (quando uma mesma família recebe parcela complementar ou retroativa na mesma competência). Em nenhuma linha `qtd_parcelas` é menor que `qtd_familias`.

- **Valores nominais.** Os campos `valor_total` e `valor_medio` estão em reais correntes, sem correção inflacionária.
