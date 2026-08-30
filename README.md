# Tarifa Zero — Coleta de dados de desfechos (ANPET)

Scripts em **R** para coletar os **desfechos** do estudo de impacto do *Tarifa Zero*
sobre poluição atmosférica e consumo de combustíveis, no nível municipal, para uso
em **controle sintético**.

Esta é a **parte do Thomas** da coleta:

- **(a) Poluição atmosférica** — CO e NOx (NO₂ troposférico) na coluna troposférica,
  via satélite **Sentinel-5P TROPOMI**, todos os municípios do Brasil, resolução
  **mensal** (2018-07 em diante).
- **(b) Consumo municipal anual de combustível (ANP)** — **Gasolina C, Etanol
  Hidratado e Óleo Diesel**, série **2010 em diante**, todos os municípios.

> As variáveis de controle (população, taxa de motorização, autonomia fiscal IFGF)
> são da parte do João e **não** estão neste repositório.

## Cidades do estudo

| Município | UF | Cód. IBGE | Tarifa Zero | Papel |
|---|---|---|---|---|
| Luziânia | GO | 5212501 | nov/2023 | tratada |
| Itapetininga | SP | 3522307 | dez/2023 | tratada |
| Paranaguá | PR | 4118204 | mar/2022 | tratada |
| Balneário Camboriú | SC | 4202008 | — | substituta |
| Sorriso | MT | 5107925 | — | substituta |

## Estrutura

```
scripts_dados/
  00_setup.R              # pacotes, parâmetros, cidades-alvo, helpers
  01_municipios_geobr.R   # malha municipal IBGE (geobr) -> lookup + geometrias
  02_anp_combustiveis.R   # vendas ANP por município -> CSV tidy + painel largo
  03_tropomi_poluicao.R   # NO2/CO mensal por município (rgee) -> CSV  [roda local]
  04_consolidar_painel.R  # junta tudo + flags das cidades tratadas
data/                     # saídas processadas (versionadas)
data-raw/                 # arquivos crus baixados (gitignored, reprodutíveis)
```

## Como rodar

Ordem: `00 → 01 → 02 → 03 → 04`. Cada script carrega `00_setup.R`.

```r
source("scripts_dados/01_municipios_geobr.R")   # malha IBGE (gera o lookup usado pela ANP)
source("scripts_dados/02_anp_combustiveis.R")   # combustíveis (baixa 45 planilhas da ANP)
source("scripts_dados/03_tropomi_poluicao.R")   # poluição (Earth Engine) — ver abaixo
source("scripts_dados/04_consolidar_painel.R")  # painéis finais
```

### Earth Engine (script 03) — roda na sua máquina

A extração de poluição usa o pacote `rgee` e **exige autenticação interativa** com a
sua conta do Google Earth Engine (não roda em servidor headless). Na 1ª vez:

```r
rgee::ee_install()        # cria o ambiente Python (uma vez)
rgee::ee_Authenticate()   # autentica no browser
Sys.setenv(EE_PROJECT = "seu-projeto-ee")   # id do seu projeto EE
```

O script exporta um CSV por ano para o seu Google Drive (evita timeout do EE) e os
baixa automaticamente para `data-raw/gee/`, consolidando em `data/`.

**Teste rápido antes da série inteira:** defina `EE_ANOS_TESTE` para rodar só
alguns anos e validar a exportação para o Drive em poucos minutos, ex.:

```r
Sys.setenv(EE_ANOS_TESTE = "2019")   # coleta só 2019; deixe vazio p/ a série completa
source("scripts_dados/03_tropomi_poluicao.R")
```

## Saídas (em `data/`)

| Arquivo | Conteúdo |
|---|---|
| `municipios_lookup.csv` | code_muni, name_muni, code_state, abbrev_state |
| `anp_vendas_municipio_2010plus.csv` | longo: code_muni, name_muni, UF, ano, produto, vendas_litros, vendas_m3 |
| `painel_combustivel_anual.csv` | largo: vendas por produto (m³) + flags das cidades |
| `poluicao_tropomi_mensal.csv` | code_muni, ano, mes, poluente, valor (mol/m²) |
| `poluicao_tropomi_anual.csv` | agregação anual (média dos meses) |
| `painel_poluicao_mensal.csv` / `painel_poluicao_anual.csv` | versão larga + flags |

## Fontes

- **Vendas de combustíveis**: ANP — *Vendas de derivados de petróleo e
  biocombustíveis*, planilhas anuais por município (gov.br/anp). Unidade original:
  **litros** (convertida para m³). Produtos antigos (2011–2016) em `.xls`; demais em
  `.xlsx`.
- **Poluição**: Sentinel-5P TROPOMI (ESA/Copernicus) via Google Earth Engine —
  `COPERNICUS/S5P/OFFL/L3_NO2` (banda `tropospheric_NO2_column_number_density`) e
  `COPERNICUS/S5P/OFFL/L3_CO` (banda `CO_column_number_density`). Unidade: mol/m².
- **Malha municipal**: IBGE via pacote `geobr` (ano 2022, CRS SIRGAS 2000 / 4674).

## Observações metodológicas (sinalizar à equipe)

- **NOx vs NO₂**: o produto satelital disponível é **NO₂ troposférico**, usado como
  proxy padrão de NOx.
- **Pré-período curto da poluição**: o TROPOMI só começa em **jul/2018** e os
  tratamentos são de 2022–2023 (Paranaguá já em mar/2022). A resolução **mensal**
  maximiza os pontos pré-intervenção; convém alinhar a granularidade do controle
  sintético com o time.
- **Cobertura da ANP**: nem todo município tem venda registrada de todos os produtos
  em todos os anos (especialmente etanol); ausências aparecem como `NA` no painel
  largo — tratar conforme a estratégia de modelagem.
