# Extração da frota de veículos por município

Script de extração e processamento dos dados de frota municipal de veículos. O script consulta a base do DENATRAN hospedada na [Base dos Dados](https://basedosdados.org/) (via BigQuery), monta um painel mensal de frota por município e tipo de veículo, e salva o resultado em formato Parquet para uso nas análises.

---

## O que o script faz

1. Descobre dinamicamente quais **tipos de veículo** existem na base a partir do ano de corte.
2. Monta uma consulta SQL que **pivota os dados já no BigQuery** — cada tipo de veículo vira uma coluna, com a frota agregada por município e mês.
3. Baixa o painel já no formato final (uma linha por município × mês).
4. Ordena, faz uma checagem de integridade e salva em Parquet.

O resultado é um painel no formato **`id_municipio × ano × mês`**, com uma coluna por tipo de veículo (valores absolutos de frota).

---

## Por que a pivotagem é feita no BigQuery

A base original vem em formato *longo* (uma linha por município × mês × tipo de veículo). O painel que precisamos é do tipo wide, com o tipo de veículos em cada coluna. Fazer o pivoteamento direto na query ajuda a minimizar gastos computacionais.

O pivoteamento é feito usando `SUM(CASE WHEN tipo_veiculo = '...' THEN quantidade ELSE 0 END)`. O agrupamento acontece no servidor, e o script recebe a base já recortada e pivotada.

As colunas são geradas dinamicamente a partir dos tipos de veículo encontrados, então o script se adapta caso a base mude suas categorias.

---

## Requisitos

### Pacotes R

```r
install.packages(c("basedosdados", "arrow"))
# piggyback só é necessário para publicar no release (ver seção final)
install.packages("piggyback")
```

### Conta no Google Cloud

A Base dos Dados é consultada via BigQuery, que exige um projeto no Google Cloud (o `billing_project_id`). O nível gratuito do BigQuery cobre até 1TB por mês, dando conta desta extração com folga, a consulta não gera custo para o tamanho desta tabela.

Na primeira execução, o pacote abre o navegador para autenticação com a conta Google do projeto.

---

## Configuração

Antes de rodar, ajuste as variáveis no início do script:

| Variável | Descrição | Exemplo |
|----------|-----------|---------|
| `BILLING_ID` | ID do projeto no Google Cloud (não o nome — confira em console.cloud.google.com) |
| `ANO_INICIAL` | Ano de corte da série (traz dados deste ano em diante) | `2006` |
| `REPO` | Repositório GitHub onde os dados são publicados como assets | `"pedreirajr/av_imp_tz"` |
| `TAG` | Tag da release usada para publicar os dados | `"dados-motorizacao"` |
| `TABELA` | Tabela de frota na Base dos Dados | `br_denatran_frota.municipio_tipo` |

---

## Como rodar

```r
source("extração_motorização.R")
```

Ou execute o script inteiro no RStudio.

É preferível que esse script seja executado primeiro no rstudio, a fim de facilitar a autenticação com o google.

---

## Saída

| Arquivo | Descrição |
|---------|-----------|
| `frota_mensal_municipio.parquet` | Painel mensal de frota por município e tipo de veículo, de `ANO_INICIAL` até o dado mais recente disponível. |

### Estrutura das colunas

| Coluna | Tipo | Descrição |
|--------|------|-----------|
| `id_municipio` | texto | Código IBGE de 7 dígitos do município |
| `id_municipio_nome` | texto | Nome do município |
| `sigla_uf` | texto | Unidade da Federação |
| `ano` | inteiro | Ano de referência |
| `mes` | inteiro | Mês de referência |
| *(uma coluna por tipo de veículo)* | inteiro | Frota absoluta daquele tipo (ex.: `automovel`, `motocicleta`, `onibus`, `caminhao`, ...) |

> Os nomes das colunas de veículo são normalizados para minúsculas, sem acentos e com `_` no lugar de caracteres especiais.

---

## Fonte dos dados

- **Frota:** DENATRAN, via [Base dos Dados](https://basedosdados.org/dataset/br-denatran-frota) — tabela `br_denatran_frota.municipio_tipo`. Os dados já vêm tratados pela Base dos Dados, com as categorias de veículo padronizadas ao longo da série (resolvendo a mudança de categorias de um ano para outro que ocorre nos arquivos brutos do SENATRAN).
- **Nomes dos municípios:** diretório oficial `br_bd_diretorios_brasil.municipio`.

---

## Publicação dos dados no release (opcional)

O trecho final do script, comentado por padrão, publica o Parquet gerado como asset de um release no GitHub, usando o pacote [`piggyback`](https://docs.ropensci.org/piggyback/). A lógica de organização do repositório é: **código versionado no repositório, dados como assets do release** — mantendo o histórico do Git leve.

Para ativar, descomente as linhas ao final:

```r
releases <- pb_releases(repo = REPO)
if (!(TAG %in% releases$tag_name)) {
  pb_new_release(repo = REPO, tag = TAG)
}
pb_upload(file = arquivo_saida, repo = REPO, tag = TAG)
```

Isso verifica se a release com a tag indicada já existe (criando-a se necessário) e envia o arquivo Parquet como asset. Requer o `piggyback` instalado e autenticação no GitHub (via variável de ambiente `GITHUB_TOKEN` ou `gh auth login`).