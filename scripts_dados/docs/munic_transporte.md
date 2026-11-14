# Módulo Transporte da MUNIC (IBGE)

Script de extração do bloco de Transporte da **Pesquisa de Informações Básicas Municipais (MUNIC)**, do IBGE. O script baixa as planilhas publicadas no FTP oficial, extrai as respostas do questionário de transporte para todos os municípios, monta o dicionário das variáveis e publica tudo como assets da release do repositório.

---

## O que o script faz

1. Baixa as bases completas da MUNIC das edições com módulo de Transporte, direto do FTP do IBGE.
2. Localiza, em cada planilha, a aba de transporte e a aba de dicionário.
3. Extrai todas as variáveis `MtraNN` e as converte para formato longo.
4. Monta o dicionário `código → descrição` de cada edição.
5. Grava os resultados em pasta temporária, publica na release e apaga os temporários.

Nada é gravado no repositório: o Git guarda apenas o código, e os dados vivem como assets da release.

---

## Edições cobertas

| Edição | Arquivo no FTP |
|---|---|
| 2017 | `Base_MUNIC_2017_xls.zip` |
| 2020 | `Base_MUNIC_2020.xlsx` |
| 2024 | `Base_MUNIC_2024_20251107.xlsx` |

A MUNIC tem 19 edições publicadas no FTP (2001 a 2024), mas o **módulo de Transporte aparece apenas nessas três** — verificado edição por edição no portal do IBGE. A pesquisa aplica blocos temáticos em rodízio, então nem todo ano traz todos os temas.

---

## Por que FTP e não `sidrar` / `ibger`

A MUNIC **está** disponível no SIDRA — são 187 tabelas sob a pesquisa `PM`, 17 delas de transporte, acessíveis pelo pacote `sidrar` e chegando ao nível municipal. Ou seja, não é caso de indisponibilidade.

O problema é que o SIDRA publica um **produto diferente**: tabulações agregadas, não as respostas do questionário.

Consultando o município de São Paulo pelas duas vias:

| | SIDRA (tabela 8453) | FTP (planilha 2024) |
|---|---|---|
| Retorno | 1 linha | 96 variáveis |
| Conteúdo | "Municípios com Plano Municipal de Transporte → 1" | `Mtra01 = Secretaria municipal exclusiva`, `Mtra04 = 47`, `Mtra06 = Especialização`, ... |
| Período | só 2020 | a edição inteira |

Três consequências práticas:

- **Os códigos `MtraNN` não existem no SIDRA.** Eles vêm do questionário da pesquisa; o SIDRA usa identificadores próprios de variável e classificação, sem correspondência publicada.
- **Não há dicionário equivalente.** A aba de dicionário está dentro do próprio arquivo do FTP.
- **Uma tabela por quesito, por edição.** Reproduzir um único arquivo exigiria descobrir e costurar dezenas de tabelas, cada uma com sua estrutura de classificações.

---

## Por que o formato longo

Os códigos **não são estáveis entre edições**. Em 2024 o IBGE inseriu o quesito "A política de financiamento extratarifário" como `MTRA084`, deslocando os seguintes:

| Código | 2017 e 2020 | 2024 |
|---|---|---|
| `MTRA084` | A estrutura... do espaço viário de uso público | **A política de financiamento extratarifário** |
| `MTRA085` | O uso pelo pedestre e pelo ciclista... | A estrutura... do espaço viário de uso público |
| `MTRA086` | A inclusão de pessoas com deficiência... | O uso pelo pedestre e pelo ciclista... |

Dos 58 códigos presentes nas três edições, 15 mudam de descrição — parte por reescrita de redação (`MTRA03`: "Sexo do(a) titular do órgão gestor" → "Sexo"), parte por deslocamento real de quesito, como acima.

Se as edições fossem empilhadas numa tabela larga, com uma coluna por código, a coluna `MTRA084` conteria duas perguntas diferentes sem qualquer sinal disso. No formato longo o significado vem do dicionário por `(ano, variavel)`, e comparar edições passa a ser uma decisão explícita de quem analisa.

> Atenção especial para este projeto: o quesito novo de 2024 trata de **financiamento extratarifário**, diretamente relacionado a políticas de tarifa zero.

---

## Requisitos

### Pacotes R

```r
install.packages(c("readxl", "dplyr", "tidyr", "purrr", "stringr", "tibble",
                   "arrow", "writexl", "piggyback"))
```

### Token do GitHub

A publicação na release exige um Personal Access Token **classic** com escopo `repo`, lido da variável `GITHUB_PAT`. Crie um `.Renviron` na raiz do projeto (já está no `.gitignore`) com:

```
GITHUB_PAT=seu_token_aqui
```

> Use token **classic**, não fine-grained. O repositório pertence a outro usuário, e tokens fine-grained só alcançam repositórios do próprio resource owner.

Não é necessária conta no Google Cloud — diferente do script do DENATRAN, esta extração não usa BigQuery.

---

## Configuração

| Variável | Descrição | Exemplo |
|---|---|---|
| `REPO` | Repositório GitHub onde os dados são publicados | `"pedreirajr/av_imp_tz"` |
| `TAG` | Tag da release usada para publicar | `"data"` |
| `fontes` | Tabela com ano e URL de cada edição | ver seção 1 do script |

A release indicada em `TAG` **precisa existir** — o script não a cria, apenas envia os assets.

---

## Como rodar

```r
source("scripts_dados/munic_transporte.R")
```

O download total é de cerca de 50 MB e costuma levar alguns minutos, dependendo da velocidade do FTP do IBGE (o `timeout` está em 600 segundos por isso).

---

## Saídas

Nenhuma fica no projeto. Todas são publicadas como assets da release:

| Asset | Conteúdo |
|---|---|
| `munic_transporte.parquet` | Painel longo: ano × município × variável |
| `munic_dicionario.xlsx` | Código → descrição, por edição |

### `munic_transporte.parquet`

Aproximadamente 1,3 milhão de linhas (3 edições × 5.570 municípios × 60 a 96 variáveis).

| Coluna | Tipo | Descrição |
|---|---|---|
| `ano` | inteiro | Edição da MUNIC (2017, 2020 ou 2024) |
| `code_muni` | texto | Código IBGE de 7 dígitos do município |
| `variavel` | texto | Código do quesito, em maiúsculas (`MTRA01`, `MTRA084`, ...) |
| `valor` | texto | Resposta registrada na pesquisa |

> `valor` é texto para todas as variáveis, porque as respostas misturam tipos — "Sim"/"Não", idades, descrições de cargo, categorias. A conversão para outros tipos fica a cargo da análise, quesito a quesito.

O nome `code_muni` segue a convenção do pacote [`geobr`](https://ipeagit.github.io/geobr/), igual ao painel do DENATRAN, facilitando o join entre as bases do projeto.

### `munic_dicionario.xlsx`

234 linhas — 60 de 2017, 77 de 2020 e 97 de 2024.

| Coluna | Tipo | Descrição |
|---|---|---|
| `ano` | inteiro | Edição a que a descrição se refere |
| `variavel` | texto | Código do quesito |
| `descricao` | texto | Descrição completa, com os níveis hierárquicos separados por ` > ` |
| `tema` | texto | Bloco temático do quesito na planilha original |

---

## Como usar

```r
dados <- arrow::read_parquet("munic_transporte.parquet")
dic   <- readxl::read_excel("munic_dicionario.xlsx")

# sempre juntar por ano E variavel — nunca só por variavel
dados |>
  dplyr::left_join(dic, by = c("ano", "variavel"))
```

> O join **precisa** incluir `ano`. Juntar apenas por `variavel` atribuiria a descrição errada aos códigos que mudaram de significado entre edições.

Para baixar os assets:

```r
piggyback::pb_download(c("munic_transporte.parquet", "munic_dicionario.xlsx"),
                       repo = "pedreirajr/av_imp_tz", tag = "data")
```

---

## Limitações conhecidas

- **Comparação entre edições exige cuidado.** Além do deslocamento de códigos descrito acima, quesitos entram e saem entre edições: 58 códigos aparecem nas três, 98 no total, e 20 existem apenas em 2024.
- **Atributos do município variam por edição.** A planilha de 2017 traz apenas o código do município; 2020 acrescenta UF, nome, faixa populacional e região; 2024 acrescenta também a população. Como essa informação não é uniforme, o painel guarda apenas `code_muni` — nome e UF devem vir do diretório de municípios ou do `geobr`.
- **Cobertura temporal esparsa.** Três pontos no tempo (2017, 2020, 2024), não uma série anual.

---

## Fonte dos dados

- **MUNIC:** IBGE, [Pesquisa de Informações Básicas Municipais](https://www.ibge.gov.br/estatisticas/sociais/protecao-social/10586-pesquisa-de-informacoes-basicas-municipais.html), bases completas publicadas em [ftp.ibge.gov.br/Perfil_Municipios](https://ftp.ibge.gov.br/Perfil_Municipios/).
- **Dicionário:** aba de dicionário incluída em cada planilha de base completa.
