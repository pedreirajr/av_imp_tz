# Dicionário de dados — módulo Transporte da MUNIC

## Identificação da base

- **Script produtor:** `scripts_dados/munic_transporte.R`
- **Documentação do pipeline:** `scripts_dados/docs/munic_transporte.md`
- **Release:** `data`, no repositório `pedreirajr/av_imp_tz`
- **Recorte temporal:** edições de 2017, 2020 e 2024 — as únicas da MUNIC com módulo de Transporte
- **Abrangência geográfica:** 5.570 municípios brasileiros em cada edição
- **Fonte:** IBGE, Pesquisa de Informações Básicas Municipais, bases completas do FTP

O pipeline publica dois assets:

| asset | conteúdo | nível da tabela | chave única | linhas |
|---|---|---|---|---:|
| `munic_transporte.parquet` | respostas do questionário de transporte | ano × município × variável | `ano`, `code_muni`, `variavel` | 1.297.810 |
| `munic_dicionario.xlsx` | descrição de cada código de variável | ano × variável | `ano`, `variavel` | 234 |

Distribuição das linhas por edição: 334.200 em 2017 (60 variáveis), 428.890 em 2020 (77 variáveis) e 534.720 em 2024 (96 variáveis).

## Colunas de `munic_transporte.parquet`

| coluna | tipo | unidade | descrição | valores possíveis | significado de `NA` |
|---|---|---|---|---|---|
| `ano` | `integer` | ano | Edição da MUNIC à qual a resposta se refere. | `2017`, `2020` ou `2024`. | Não permitido pelo pipeline. |
| `code_muni` | `character` | — | Código IBGE de sete dígitos do município. Mantido como texto para preservar zeros à esquerda. | Códigos municipais de sete dígitos presentes na planilha da edição. | Não permitido pelo pipeline. |
| `variavel` | `character` | — | Código do quesito no questionário, normalizado para maiúsculas. | `MTRA01` a `MTRA23x`; o conjunto varia por edição. Ver `munic_dicionario.xlsx`. | Não permitido pelo pipeline. |
| `valor` | `character` | — | Resposta registrada na pesquisa, exatamente como publicada pelo IBGE. | Texto livre: `Sim`, `Não`, `-`, idades em anos, categorias de escolaridade, cargos, etc. | 70 ocorrências (0,0%) — célula vazia na planilha de origem. Distinto de `-`. |

> `valor` é texto para **todas** as variáveis. As respostas misturam naturezas — binárias, numéricas, categóricas e descritivas — e o pipeline não converte tipos. A conversão fica a cargo da análise, quesito a quesito.

## Colunas de `munic_dicionario.xlsx`

| coluna | tipo | unidade | descrição | valores possíveis | significado de `NA` |
|---|---|---|---|---|---|
| `ano` | `integer` | ano | Edição a que a descrição se refere. | `2017`, `2020` ou `2024`. | Não permitido pelo pipeline. |
| `variavel` | `character` | — | Código do quesito, em maiúsculas. | 60 códigos em 2017, 77 em 2020 e 97 em 2024. | Não permitido pelo pipeline. |
| `descricao` | `character` | — | Descrição do quesito. Quando a planilha distribui o enunciado por níveis hierárquicos, eles são concatenados com ` > `. | Texto livre. | Não permitido pelo pipeline. |
| `tema` | `character` | — | Bloco temático do quesito na planilha original, preenchido para baixo a partir do cabeçalho do bloco. | `Caracterização do órgão gestor`, `Perfil do gestor`, `Plano Municipal de Transporte - existência`, entre outros. | Não permitido pelo pipeline. |

## Valores especiais em `valor`

| valor | ocorrências | participação | significado |
|---|---:|---:|---|
| `-` | 750.671 | 57,8% | **Não aplicável.** O quesito não foi perguntado em função de uma resposta anterior. |
| `Não` | 338.719 | 26,1% | Resposta negativa. |
| `Sim` | 125.459 | 9,7% | Resposta afirmativa. |
| `NA` | 70 | 0,0% | Célula vazia na planilha de origem. |

O `-` decorre do encadeamento do questionário. Exemplo observado em Alta Floresta D'Oeste (RO) em 2024:

```
MTRA07    Não   Plano Municipal de Transporte - existência
MTRA081   -     A política de circulação viária e de transportes
MTRA083   -     A política tarifária
MTRA084   -     A política de financiamento extratarifário
```

O município declarou não possuir Plano Municipal de Transporte, de modo que os quesitos sobre o conteúdo do plano não se aplicam.

## Correspondência entre a fonte e a saída

| origem na planilha | coluna final | tratamento |
|---|---|---|
| Aba cujo nome contém "transp" | — | Localizada por busca no nome das abas, pois varia entre edições. |
| Coluna com código IBGE de 7 dígitos | `code_muni` | Identificada por padrão `^\d{7}$` em mais de 90% das linhas; renomeada para a convenção `geobr`. |
| Colunas `MtraNN` | `variavel`, `valor` | Convertidas de formato largo para longo; o nome da coluna vira `variavel` em maiúsculas e o conteúdo vira `valor`. |
| Ano da edição | `ano` | Atribuído a partir da fonte, não lido da planilha. |
| Aba cujo nome contém "dicion" | `variavel`, `descricao`, `tema` | Coluna `variável` fornece o código; as demais colunas de texto são concatenadas na descrição. |
| `Uf`, `Desc Mun`, `Populacao`, `Regiao`, `Faixa_populacao` | *(descartadas)* | Presentes de forma desigual entre edições — 2017 traz apenas o código do município. Nome e UF devem vir do `geobr` ou do diretório de municípios. |

## Regras de interpretação

1. **O join com o dicionário deve incluir `ano`.** Juntar apenas por `variavel` atribui descrição errada aos códigos que mudaram de significado entre edições.
2. **Os códigos não são estáveis ao longo do tempo.** Em 2024 o IBGE inseriu o quesito "A política de financiamento extratarifário" como `MTRA084`, deslocando os seguintes: o `MTRA084` de 2017 e 2020 corresponde ao `MTRA085` de 2024. Dos 58 códigos presentes nas três edições, 15 mudam de descrição.
3. **`-` não é ausência de informação.** É não aplicabilidade determinada pelo questionário, e deve ser distinguido de `NA` nas contagens e proporções.
4. **O conjunto de variáveis difere entre edições.** São 98 códigos distintos no total, dos quais 58 aparecem nas três edições e 20 existem apenas em 2024. A tabela longa não é um painel balanceado.
5. **Não há série anual.** As três edições são pontos isolados no tempo (2017, 2020, 2024), não uma série contínua.
6. **Nenhuma conversão de tipo foi aplicada.** Idades, por exemplo, estão como texto e precisam de conversão explícita antes de uso numérico.
