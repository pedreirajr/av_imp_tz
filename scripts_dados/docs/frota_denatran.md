# Extração da frota de veículos por município

Script de extração e processamento dos dados de frota municipal de veículos. O script consulta a base do DENATRAN hospedada na [Base dos Dados](https://basedosdados.org/) (via BigQuery), monta um painel mensal de frota por município e tipo de veículo, e publica o resultado em Parquet como asset de uma release do GitHub.

---

## O que o script faz

1. Descobre dinamicamente quais **tipos de veículo** existem na base a partir do ano de corte.
2. Monta uma consulta SQL que **pivota os dados já no BigQuery** — cada tipo de veículo vira uma coluna, com a frota agregada por município e mês.
3. Baixa o painel já no formato final (uma linha por município × mês).
4. Ordena, faz uma checagem de integridade e grava em Parquet numa pasta temporária.
5. Publica o arquivo como asset da release e apaga o temporário.

O resultado é um painel no formato **`code_muni × ano × mês`**, com uma coluna por tipo de veículo (valores absolutos de frota).

---

## Por que a pivotagem é feita no BigQuery

A base original vem em formato *longo* (uma linha por município × mês × tipo de veículo). O painel que precisamos é do tipo wide, com o tipo de veículos em cada coluna. Fazer o pivoteamento direto na query ajuda a minimizar gastos computacionais.

O pivoteamento é feito usando `SUM(CASE WHEN tipo_veiculo = '...' THEN quantidade ELSE 0 END)`. O agrupamento acontece no servidor, e o script recebe a base já recortada e pivotada.

Na prática a diferença é grande: no formato longo a consulta devolveria cerca de 28 milhões de linhas, contra 1,3 milhão já pivotadas.

As colunas são geradas dinamicamente a partir dos tipos de veículo encontrados, então o script se adapta caso a base mude suas categorias.

---

## Por que nada é gravado no repositório

O arquivo Parquet é escrito em `tempdir()`, enviado para a release e apagado em seguida. A lógica de organização do repositório é: **código versionado no Git, dados como assets da release** — mantendo o histórico leve e evitando que arquivos de dados sejam commitados por engano.

---

## Requisitos

### Pacotes R

```r
install.packages(c("basedosdados", "arrow", "piggyback"))
```

### Conta no Google Cloud

A Base dos Dados é consultada via BigQuery, que exige um projeto no Google Cloud (o `billing_project_id`). O nível gratuito do BigQuery cobre até 1TB por mês, dando conta desta extração com folga, a consulta não gera custo para o tamanho desta tabela.

Na primeira execução, o pacote abre o navegador para autenticação com a conta Google do projeto.

### Token do GitHub

A publicação na release exige um Personal Access Token com escopo `repo`, lido da variável de ambiente `GITHUB_PAT`. Crie um arquivo `.Renviron` na raiz do projeto (ele está no `.gitignore` e não vai para o repositório) com:

```
GITHUB_PAT=seu_token_aqui
```

Gere o token em [github.com/settings/tokens](https://github.com/settings/tokens) e reinicie a sessão do R depois de criar o arquivo.

---

## Configuração

Antes de rodar, ajuste as variáveis no início do script:

| Variável | Descrição | Exemplo |
|----------|-----------|---------|
| `BILLING_ID` | ID do projeto no Google Cloud (não o nome — confira em console.cloud.google.com) | `"meu-projeto-123456"` |
| `ANO_INICIAL` | Ano de corte da série (traz dados deste ano em diante) | `2006` |
| `REPO` | Repositório GitHub onde os dados são publicados como assets | `"pedreirajr/av_imp_tz"` |
| `TAG` | Tag da release usada para publicar os dados | `"data"` |
| `TABELA` | Tabela de frota na Base dos Dados | `br_denatran_frota.municipio_tipo` |

A release indicada em `TAG` **precisa existir** — o script não a cria, apenas envia o asset.

---

## Como rodar

```r
source("scripts_dados/frota_denatran.R")
```

Ou execute o script inteiro no RStudio.

É preferível que esse script seja executado primeiro no rstudio, a fim de facilitar a autenticação com o google.

---

## Saída

O script não deixa arquivo no projeto. A saída é o asset publicado na release:

| Asset | Descrição |
|---------|-----------|
| `frota_mensal_municipio.parquet` | Painel mensal de frota por município e tipo de veículo, de `ANO_INICIAL` até o dado mais recente disponível. |

Para usar os dados em outro script, baixe da release:

```r
piggyback::pb_download("frota_mensal_municipio.parquet",
                       repo = "pedreirajr/av_imp_tz", tag = "data")
```

### Estrutura das colunas

Os nomes seguem a convenção do pacote [`geobr`](https://ipeagit.github.io/geobr/), para facilitar o join com as malhas territoriais.

| Coluna | Tipo | Descrição |
|--------|------|-----------|
| `code_muni` | texto | Código IBGE de 7 dígitos do município |
| `name_muni` | texto | Nome do município |
| `abbrev_state` | texto | Sigla da Unidade da Federação |
| `ano` | inteiro | Ano de referência |
| `mes` | inteiro | Mês de referência |
| *(uma coluna por tipo de veículo)* | inteiro | Frota absoluta daquele tipo (ex.: `automovel`, `motocicleta`, `onibus`, `caminhao`, ...) |

> Os nomes das colunas de veículo são normalizados para minúsculas, sem acentos e com `_` no lugar de caracteres especiais — `micro-onibus` vira `micro_onibus`, `caminhao trator` vira `caminhao_trator`.

---

## Lacunas conhecidas da série

A série **não é completa**. Três lacunas foram identificadas no painel publicado e vêm da fonte, não da extração:

**1. Janeiro de 2024 não existe.** O ano de 2024 tem apenas os meses 2 a 12. Dos 241 meses esperados entre jan/2006 e jan/2026, o painel tem 240.

**2. 2026 vai só até janeiro.** Não é falha, é a fronteira dos dados — a Base dos Dados ainda não publicou os meses seguintes. O recorte efetivo da série termina em jan/2026.

**3. Alagoas tem cobertura parcial em 2006.** O estado tem 102 municípios, mas de janeiro a outubro de 2006 apenas 17 a 20 deles aparecem na base. A cobertura completa começa em novembro:

```
AL 2006:  jan=19  fev=19  mar=19  abr=18  mai=19  jun=18
          jul=18  ago=18  set=20  out=17  nov=102 dez=102
```

Alagoas é a única UF com esse comportamento — nenhuma outra varia ao longo de 2006. Note que há dado parcial no período, não ausência total.

Para contexto, a contagem de municípios por mês ao longo da série:

| Período | Municípios por mês |
|---|---|
| 2006 | 5.477 a 5.562 (efeito da lacuna de Alagoas) |
| 2007–2013 | 5.562 → 5.570 (criação de municípios novos) |
| 2014–2024 | 5.570 |
| 2025–2026 | 5.571 |

A variação entre 2007 e 2013 é legítima: reflete municípios criados no período, não falha de cobertura.

---

## Fonte dos dados

- **Frota:** DENATRAN, via [Base dos Dados](https://basedosdados.org/dataset/br-denatran-frota) — tabela `br_denatran_frota.municipio_tipo`. Os dados já vêm tratados pela Base dos Dados, com as categorias de veículo padronizadas ao longo da série (resolvendo a mudança de categorias de um ano para outro que ocorre nos arquivos brutos do SENATRAN).
- **Nomes dos municípios:** diretório oficial `br_bd_diretorios_brasil.municipio`.

---

## Publicação na release

O trecho final do script envia o Parquet como asset da release indicada em `TAG`, usando o pacote [`piggyback`](https://docs.ropensci.org/piggyback/):

```r
pb_upload(file = arquivo_saida, repo = REPO, tag = TAG, overwrite = TRUE)
unlink(arquivo_saida)
```

O `overwrite = TRUE` é necessário para que reexecuções substituam o asset existente — sem ele, o GitHub recusa o envio com **HTTP 422** quando já há um arquivo com aquele nome na release.

O script **não cria releases**. Se a tag informada não existir, o `pb_upload` falha — comportamento intencional, para que um erro de digitação na `TAG` não gere uma release solta no repositório.
