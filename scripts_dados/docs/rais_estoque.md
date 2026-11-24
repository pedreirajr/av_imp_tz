# Documentação: RAIS Estoque Anual Municipal

## Fonte

- **Instituição primária:** Ministério do Trabalho e Emprego (MTE) / Programa de Disseminação das Estatísticas do Trabalho (PDET) — Relação Anual de Informações Sociais (RAIS), microdados públicos de vínculos empregatícios.
- **Página oficial da fonte:** <https://www.gov.br/trabalho-e-emprego/pt-br/acesso-a-informacao/acoes-e-programas/programas-projetos-acoes-obras-e-atividades/estatisticas-trabalho/microdados-rais-e-caged>
- **FTP oficial do MTE:** `ftp://ftp.mtps.gov.br/pdet/microdados/RAIS/`
- **Repositório de extração utilizado:** Base dos Dados (`basedosdados.br_me_rais.microdados_vinculos`), catálogo em <https://basedosdados.org/dataset/br-me-rais>.
- **Data da extração e auditoria:** 24/11/2026.

### Escolha da fonte: avaliação empírica de `raisr` (FTP do MTE) vs. Base dos Dados

Antes de adotar a agregação no BigQuery (padrão já adotado em `scripts_dados/frota_denatran.R` e `scripts_dados/bolsa_familia.R`), o pacote `raisr` (`v0.1.0`, CRAN) foi instalado e testado em 24/11/2026 contra o FTP oficial do PDET/MTE:

1. **Catálogo e volume no FTP oficial (`raisr::rais_available(2009:2025)`):** os 17 anos finais (`2009` a `2025`) somam **295 arquivos `.7z`** (27 arquivos estaduais por ano em `2009`–`2017`; 6 arquivos macro-regionais por ano em `2018`–`2021`; 7 arquivos em `2022`–`2025`, incluindo `RAIS_VINC_PUB_NI.7z`), totalizando **38,37 GB compactados** (~1,24 bilhão de vínculos).
2. **Vazão real e tempo projetado:** o download de `AC2009.7z` (`2,6 MB`) levou `4,2 s` (`0,62 MB/s`) mais `3,2 s` de leitura em *streaming*; o arquivo `RAIS_VINC_PUB_NORTE.7z` (`2025`, `202 MB`) excedeu `3m42s` (`< 0,90 MB/s`). Nessa taxa, baixar e ler todos os 295 arquivos de `2009`–`2025` exigiria **~18 a 25 horas** por máquina.
3. **Limitações operacionais observadas no `raisr` (`v0.1.0`):** `raisr::rais_stock()` agrupa com `interaction(keys, drop = TRUE)`, descartando linhas com `municipio = NA`; `raisr::rais_files()` filtrado pelas 27 UFs omite `RAIS_VINC_PUB_NI.7z`; e as pastas `2023/` e `2024/` do FTP contêm arquivos `.htm` com nomes em Latin-1 que exigem conversão explícita sob locale UTF-8 no Windows.
4. **Desempenho e fidelidade da Base dos Dados:** a consulta agregada sobre `basedosdados.br_me_rais.microdados_vinculos` cobre exatamente os mesmos 17 anos (**`2009` a `2025`**, sem bloqueio de *Row-Level Security*), estima **27,69 GB** no *dry-run* (2,7% da franquia gratuita de 1 TB/mês), executa de ponta a ponta em **33,3 segundos** e fecha com **zero diferença** frente aos arquivos oficiais do FTP lidos pelo `raisr` (ver conferência abaixo).

## O que o script faz

Script: `scripts_dados/rais_estoque.R`.

1. Monta uma consulta Standard SQL sobre `basedosdados.br_me_rais.microdados_vinculos` filtrando `ano >= 2009`, agregando por `ano`, `sigla_uf_fonte` e `id_municipio_fonte` e contando `COUNTIF(TRIM(CAST(vinculo_ativo_3112 AS STRING)) = '1')` como `vinculos_ativos`.
2. Consulta sempre o BigQuery por padrão (`usar_cache = FALSE`). Antes da execução real, realiza um *dry-run* gratuito (`bigrquery::bq_perform_query_dry_run()`) e aplica trava dupla de volume de leitura (`250 GB` no cliente e `maximumBytesBilled` no servidor). O resumo agregado (~1 MB) é salvo em cache local fora do repositório (`tools::R_user_dir("av_imp_tz_rais_estoque", "cache")`), mas só é reutilizado quando a flag `--usar-cache` é informada explicitamente.
3. Constrói a referência territorial do `geobr` (2022) unindo `geobr::read_municipality(year = 2022, simplified = TRUE)` e `geobr::lookup_muni(year = 2022, name_muni = "all")` (5.571 unidades oficiais, cobrindo simultaneamente Fernando de Noronha `2605459` e Boa Esperança do Norte `5101837`).
4. Converte códigos IBGE de 7 dígitos (ou 6 dígitos sem dígito verificador) para `code_muni` inteiro de 7 dígitos, obtém `name_muni`, `abbrev_state` e `code_state` exclusivamente do `geobr`, preserva em linha própria registros sem município identificado (`code_muni = NA`, `name_muni = NA`, com UF conhecida ou `99`/`"NI"`) e interrompe com erro diante de qualquer código desconhecido ou incompatível com a UF.
5. Executa travas rígidas em `validar_rais_estoque()`: bloqueia saída vazia, divergência de esquema, duplicatas na chave `ano × code_state × code_muni`, `NA` em colunas obrigatórias, buracos no calendário anual, ausência de qualquer uma das 27 UFs em qualquer ano, valores negativos/não finitos em `vinculos_ativos` e qualquer divergência de soma por `(ano, code_state)` contra a consulta bruta.
6. Grava `rais_estoque_anual_municipio.parquet` (`0,59 MB`, 94.677 linhas) exclusivamente em `tempdir()`. Com `--publicar`, envia o asset para a release `data` via `piggyback::pb_upload(..., overwrite = TRUE)` e apaga o temporário com `unlink()` em `on.exit()`, inclusive em caso de erro no upload.

## Requisitos

- Pacotes R: `bigrquery`, `dplyr`, `geobr`, `sf`, `arrow`, `jsonlite` (e `piggyback`, `gh`, `httr` para `--publicar`; `testthat` e `bit64` para a suíte de testes).
- Projeto Google Cloud com API do BigQuery habilitada (funciona no BigQuery Sandbox gratuito com cota de 1 TB/mês). Definir `BILLING_ID=<id-do-projeto>` no arquivo `.Renviron` na raiz do repositório (nunca versionado) e autenticar via `bigrquery::bq_auth()`.
- Para publicar na release (`--publicar`), token do GitHub com permissão de escrita em `GITHUB_PAT` ou configurado via `gitcreds`.

Execução a partir da raiz do repositório:

```bash
Rscript scripts_dados/rais_estoque.R
Rscript scripts_dados/rais_estoque.R --publicar
Rscript scripts_dados/rais_estoque.R --usar-cache
Rscript scripts_dados/tests/test_rais_estoque.R
```

## Conferência externa (MTE oficial e FTP via `raisr`)

### 1. Totais nacionais contra divulgações oficiais do MTE

Os totais nacionais de `vinculos_ativos` (somando todas as linhas do Parquet, inclusive `99`/`"NI"`) foram comparados com os estoques oficiais em 31 de dezembro publicados pelo MTE:

| Ano-base | `vinculos_ativos` (Parquet) | Total oficial MTE | Diferença | Observação metodológica |
| ---: | ---: | ---: | ---: | --- |
| 2009 | 41.207.546 | 41.207.546 | 0 (0,00%) | Série histórica GDRAIS |
| 2010 | 44.068.355 | 44.068.355 | 0 (0,00%) | Série histórica GDRAIS |
| 2013 | 48.948.433 | 48.948.433 | 0 (0,00%) | Ingresso dos 5 municípios emancipados em 2013 |
| 2015 | 48.060.807 | 48.060.807 | 0 (0,00%) | Série histórica GDRAIS |
| 2018 | 46.631.115 | 46.631.115 | 0 (0,00%) | Início da distribuição em arquivos regionais |
| 2019 | 46.716.492 | 46.716.492 | 0 (0,00%) | Início gradual da substituição pelo eSocial |
| 2020 | 46.236.176 | 46.236.176 | 0 (0,00%) | Transição GDRAIS/eSocial |
| 2021 | 48.728.871 | 48.728.871 | 0 (0,00%) | Transição GDRAIS/eSocial; 14 vínculos em `NI` |
| 2022 | 52.790.864 | 52.790.864 | 0 (0,00%) | Consolidação eSocial; 1.925 vínculos em `NI` |
| 2023 | 55.818.007 | 55.818.007 | 0 (0,00%) | Republicação MTE/eSocial de maio/2026 (1ª divulgação em `Legado/` tinha 54.706.385) |
| 2024 | 57.800.651 | 57.800.651 | 0 (0,00%) | Republicação MTE/eSocial de maio/2026 |
| 2025 | 60.691.770 | 60.691.770 | 0 (0,00%) | Publicação MTE/eSocial de maio/2026 |

### 2. Conferência direta município a município contra o FTP oficial (`raisr`)

- **Acre, ano-base `2009` (`AC2009.7z`):** todos os **22 municípios** do estado foram comparados individualmente entre o Parquet gerado e o arquivo baixado diretamente do FTP do MTE via `raisr::rais_read()`, apresentando **diferença máxima absoluta igual a `0`** (`106.013` vínculos ativos em ambas as fontes; ex.: Acrelândia `690`, Brasiléia `1.155`, Cruzeiro do Sul `5.960`).
- **Não identificados, ano-base `2025` (`RAIS_VINC_PUB_NI.7z`):** o arquivo oficial do FTP contém `6.208` registros com código `999999` e exatamente **`3.066` vínculos ativos em 31/12**, idêntico à linha `ano = 2025`, `code_state = 99`, `abbrev_state = "NI"`, `code_muni = NA` do Parquet (`3.066`).

## Problemas, lacunas e cuidados

- **Quebra de série metodológica (GDRAIS → eSocial) e republicação de maio/2026.** A partir do ano-base `2019`, a captação da RAIS migrou gradualmente da declaração GDRAIS para os eventos contínuos do **eSocial** (consolidados em `2022` e reformulados no layout de `2023` em diante). Em maio de 2026, o MTE republicou os microdados de `2023` (elevando o total de `54.706.385` na versão inicial, hoje na pasta `Legado/` do FTP, para `55.818.007`) e divulgou `2024` (`57.800.651`) e `2025` (`60.691.770`). O próprio MTE alerta que saltos de nível em `2022`–`2023` refletem parcialmente maior cobertura cadastral do eSocial; análises longitudinais devem incluir efeitos fixos de ano ou checar sensibilidade pré/pós-2022.

- **Uso como denominador dos fluxos mensais do CAGED (`caged_movimentacoes_mensais.parquet`).** Para expressar admissões, desligamentos e saldo mensais do CAGED no ano $t$ e mês $m$ em termos percentuais sem endogeneidade intra-anual, recomenda-se usar o estoque da RAIS em **31 de dezembro do ano anterior** (`rais$ano == caged$ano - 1L`), ou o estoque mensal evoluído $E_{i,t,m-1} = E_{i,t-1} + \sum_{k=1}^{m-1} \text{saldo}_{i,t,k}$. Dois cuidados metodológicos são indispensáveis:
  1. **Escopo contratual distinto:** a RAIS inclui vínculos estatutários e do setor público além de celetistas, enquanto o CAGED registra apenas movimentações celetistas (CLT). Assim, a razão `fluxo_caged / vinculos_ativos_rais` representa a movimentação celetista como proporção do estoque total formal (público + privado) do município.
  2. **Evitar divisão por zero:** nos dois casos com `vinculos_ativos = 0` (`Guaribas-PI` em `2010` como denominador de `2011`, e `Marajá do Sena-MA` em `2015` como denominador de `2016`), a taxa percentual deve ser atribuída como `NA`.

- **Diferença entre `vinculos_ativos = 0` (2 linhas) e ausência de linha (1 município em `2009`).**
  - **2 linhas com estoque `0` real:** `Guaribas` (PI, `2204550`, `2010`) e `Marajá do Sena` (MA, `2106359`, `2015`) aparecem nos microdados da RAIS nesses anos, mas sem nenhum vínculo com `vinculo_ativo_3112 = '1'` (todos os vínculos declarados foram encerrados antes de 31/12).
  - **Ausência na fonte em `2009`:** `São Roberto` (MA, `2111672`) não possui registros na RAIS `2009` (totalizando 5.564 municípios em `2009` contra 5.565 em `2010`–`2012`). Conforme a regra do projeto (*ausência de dado não é zero*), nenhuma linha sintética com `0` foi criada.

- **Emancipações municipais (`2013` e `2023`) e Fernando de Noronha (`2605459`).**
  - Os 5 municípios instalados em `2013` passam a constar na RAIS exatamente em `2013` (elevando a cobertura de 5.565 para 5.570 municípios): `Mojuí dos Campos` (PA, `1504752`), `Pescaria Brava` (SC, `4212650`), `Balneário Rincão` (SC, `4220000`), `Pinto Bandeira` (RS, `4314548`) e `Paraíso das Águas` (MS, `5006275`).
  - `Boa Esperança do Norte` (MT, `5101837`) ingressa na RAIS a partir de `2023` (elevando a cobertura para 5.571 unidades em `2023`–`2025`), com `143` vínculos ativos em `2023`, `945` em `2024` e `1.047` em `2025`.
  - `Fernando de Noronha` (PE, `2605459`) aparece em todos os 17 anos (`1.025` vínculos em `2009` até `2.828` em `2025`), preservado graças à combinação de `read_municipality(2022)` e `lookup_muni(2022)` do `geobr`.

- **5 linhas sem UF/município identificados (`code_state = 99`, `abbrev_state = "NI"`, `code_muni = NA`).** Presentes de `2021` a `2025` (`14` vínculos em `2021`, `1.925` em `2022`, `829` em `2023`, `11.125` em `2024` e `3.066` em `2025`, somando `16.959` vínculos — 0,006% do estoque acumulado nesses cinco anos). Foram preservadas para fechamento exato com os totais oficiais do MTE e conferem integralmente com `RAIS_VINC_PUB_NI.7z` em `2025`.

- **Unidade estatística (`vínculos` ≠ `pessoas`).** Cada linha dos microdados representa um vínculo empregatício; trabalhadores com múltiplos vínculos ativos em 31 de dezembro são contabilizados em cada vínculo.
