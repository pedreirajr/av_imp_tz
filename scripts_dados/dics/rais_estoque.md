# Dicionário de dados: RAIS Estoque Anual Municipal

## Identificação da base

- **Asset publicado:** `rais_estoque_anual_municipio.parquet` (release `data`, repositório `pedreirajr/av_imp_tz`)
- **Script produtor:** `scripts_dados/rais_estoque.R`
- **Fonte primária:** Ministério do Trabalho e Emprego (MTE) / PDET — Relação Anual de Informações Sociais (RAIS), microdados públicos de vínculos consolidados na Base dos Dados (`basedosdados.br_me_rais.microdados_vinculos`).
- **Nível de observação:** município × ano.
- **Chave única:** `ano` × `code_state` × `code_muni`.
- **Período:** `2009` a `2025` (17 anos contínuos na auditoria de 24/11/2026).
- **Abrangência:** 27 UFs e entre 5.564 e 5.571 municípios identificados na referência territorial `geobr` 2022 (incluindo Distrito Federal, Fernando de Noronha e Boa Esperança do Norte), totalizando **94.677 linhas** (incluindo 5 linhas sem UF/município identificados entre `2021` e `2025`, somando 16.959 vínculos).

## Cobertura anual auditada (24/11/2026)

| `ano` | linhas | municípios identificados | linhas `NI` (`code_muni = NA`) | vínculos `NI` | linhas com `vinculos_ativos = 0` | total Brasil (`vinculos_ativos`) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2009 | 5.564 | 5.564 | 0 | 0 | 0 | 41.207.546 |
| 2010 | 5.565 | 5.565 | 0 | 0 | 1 | 44.068.355 |
| 2011 | 5.565 | 5.565 | 0 | 0 | 0 | 46.310.631 |
| 2012 | 5.565 | 5.565 | 0 | 0 | 0 | 47.458.712 |
| 2013 | 5.570 | 5.570 | 0 | 0 | 0 | 48.948.433 |
| 2014 | 5.570 | 5.570 | 0 | 0 | 0 | 49.571.510 |
| 2015 | 5.570 | 5.570 | 0 | 0 | 1 | 48.060.807 |
| 2016 | 5.570 | 5.570 | 0 | 0 | 0 | 46.060.198 |
| 2017 | 5.570 | 5.570 | 0 | 0 | 0 | 46.281.590 |
| 2018 | 5.570 | 5.570 | 0 | 0 | 0 | 46.631.115 |
| 2019 | 5.570 | 5.570 | 0 | 0 | 0 | 46.716.492 |
| 2020 | 5.570 | 5.570 | 0 | 0 | 0 | 46.236.176 |
| 2021 | 5.571 | 5.570 | 1 | 14 | 0 | 48.728.871 |
| 2022 | 5.571 | 5.570 | 1 | 1.925 | 0 | 52.790.864 |
| 2023 | 5.572 | 5.571 | 1 | 829 | 0 | 55.818.007 |
| 2024 | 5.572 | 5.571 | 1 | 11.125 | 0 | 57.800.651 |
| 2025 | 5.572 | 5.571 | 1 | 3.066 | 0 | 60.691.770 |

## Colunas

| nome original na fonte | coluna | tipo | unidade | descrição | valores possíveis e `NA` |
| --- | --- | --- | --- | --- | --- |
| `ano` | `ano` | `integer` | ano | Ano-base de referência da RAIS; o estoque retrata a posição em **31 de dezembro** desse ano. | Inteiros contínuos de `2009` a `2025`. Não tem `NA`. |
| — (`geobr` / `sigla_uf`) | `code_state` | `integer` | — | Código IBGE da UF (2 dígitos), obtido do `geobr` 2022 a partir de `code_muni` (ou da `sigla_uf` da fonte quando `code_muni` é `NA`). | Códigos IBGE das 27 UFs (`11` a `53`) e `99` para UF não identificada (5 linhas em `2021`–`2025`). Não tem `NA`. |
| — (`geobr` / `sigla_uf`) | `abbrev_state` | `character` | — | Sigla oficial da UF obtida do `geobr` 2022 a partir de `code_muni` (ou `"NI"` quando UF não identificada). | As 27 siglas de UF (`AC` a `TO`) e `"NI"` (5 linhas em `2021`–`2025`). Não tem `NA`. |
| `id_municipio` | `code_muni` | `integer` | — | Código IBGE do município (7 dígitos), reconciliado exclusivamente contra `geobr` 2022 (`read_municipality` + `lookup_muni`). | Até 5.571 códigos municipais válidos. `NA` exclusivamente em registros sem município identificado na fonte (5 linhas `99`/`"NI"` em `2021`–`2025`). |
| — (`geobr`) | `name_muni` | `character` | — | Nome oficial do município obtido exclusivamente do `geobr` 2022. | Nomes oficiais do `geobr`. `NA` exclusivamente quando `code_muni` é `NA` (5 linhas). |
| `COUNTIF(vinculo_ativo_3112 = '1')` | `vinculos_ativos` | `integer` | vínculos ativos em 31/12 | Estoque de vínculos empregatícios formais ativos em 31 de dezembro do ano-base no município. Mede vínculos (um mesmo trabalhador pode manter mais de um vínculo formal simultâneo), e não pessoas únicas. | Inteiro não negativo (`>= 0`). Há 2 linhas com valor `0` real (`Guaribas-PI` em `2010` e `Marajá do Sena-MA` em `2015`). Não tem `NA`. |

## Regras de interpretação

1. **Cruzamento com o CAGED mensal para fluxos percentuais.** Como `vinculos_ativos` mede o estoque em **31 de dezembro** do ano `ano`, o denominador pré-período para os fluxos mensais de `caged_movimentacoes_mensais.parquet` no ano $t$ (meses 1 a 12) é o estoque da RAIS em **`ano == t - 1`** (ou o estoque mensal evoluído $E_{i,t,m-1} = E_{i,t-1} + \sum_{k=1}^{m-1} \text{saldo}_{i,t,k}$). Por isso a base inicia em `2009`, fornecendo denominador para todos os meses do CAGED desde `2010-01`. Trate os 2 registros com `vinculos_ativos == 0` (`2204550` em `2010` e `2106359` em `2015`) como `NA` ao calcular razões percentuais para evitar divisão por zero (`Inf`/`NaN`).
2. **Diferença entre `0` e ausência de linha.** Um registro com `vinculos_ativos = 0` indica que o município constava nos microdados da RAIS naquele ano, mas todos os vínculos declarados foram desligados antes de 31 de dezembro. Já a **ausência de linha** indica município ainda não instalado/emancipado ou sem registro na fonte naquele ano (caso de São Roberto-MA `2111672` em `2009`, dos 5 municípios instalados em `2013` no período `2009`–`2012` e de Boa Esperança do Norte-MT `5101837` em `2009`–`2022`); ausência nunca é preenchida com `0`.
3. **Linhas `99`/`"NI"` sem município identificado.** Os 5 registros sem município e sem UF identificados (`2021` a `2025`, total de 16.959 vínculos) correspondem aos arquivos `RAIS_VINC_PUB_NI.7z` do MTE e permanecem em linha própria com `code_muni = NA` para que a soma da tabela feche exatamente com o total nacional oficial sem duplicar linhas agregadas.
4. **Quebra metodológica (GDRAIS → eSocial) e detalhes completos** de auditoria externa contra o MTE constam em `scripts_dados/docs/rais_estoque.md`.
