# Documentação do pipeline — combustíveis da ANP

## Visão geral

O script `scripts_dados/Dados_da_ANP/anp_combustiveis.R` baixa, trata e publica quatro séries anuais municipais da Agência Nacional do Petróleo, Gás Natural e Biocombustíveis (ANP): etanol hidratado, gasolina C, GLP e óleo diesel.

Os dados são recortados a partir de 2010, reconciliados com a referência municipal do `geobr`, gravados em Parquet com compressão Snappy e, quando solicitado, publicados como assets da release `data` do repositório `pedreirajr/av_imp_tz`.

Esta documentação descreve o comportamento do script e os resultados de uma execução de auditoria feita em **13/11/2026**, com publicação desativada. Como a página da ANP é atualizada, contagens e ano final devem ser conferidos novamente a cada publicação.

## Fonte dos dados

- **Órgão:** Agência Nacional do Petróleo, Gás Natural e Biocombustíveis (ANP)
- **Página oficial:** [Vendas de derivados de petróleo e biocombustíveis](https://www.gov.br/anp/pt-br/centrais-de-conteudo/dados-abertos/vendas-de-derivados-de-petroleo-e-biocombustiveis)
- **Arquivos de origem:** CSV anuais por município, um para cada combustível
- **Data da extração auditada:** 13/11/2026
- **Referência territorial:** `geobr::lookup_muni(year = 2022, name_muni = "all")`

O script não fixa as URLs diretas dos CSVs. Ele lê a página oficial, exige encontrar exatamente um link para cada nome de arquivo esperado e só então faz os downloads. Cada download usa até cinco tentativas e precisa retornar HTTP 200.

## Assets produzidos

| asset | granularidade | chave única | período | linhas em 13/11/2026 |
|---|---|---|---|---:|
| `vendas-anuais-de-etanol-hidratado-por-municipio.parquet` | município × ano | `code_muni`, `ano` | 2010–2024 | 69.375 |
| `vendas-anuais-de-gasolina-c-por-municipio.parquet` | município × ano | `code_muni`, `ano` | 2010–2024 | 81.607 |
| `vendas-anuais-de-glp-por-municipio.parquet` | município × ano × tipo de vasilhame | `code_muni`, `ano`, `tipo_vasilhame` | 2010–2024 | 134.536 |
| `vendas-anuais-de-oleo-diesel-por-municipio.parquet` | município × ano | `code_muni`, `ano` | 2010–2024 | 81.793 |

O dicionário completo das colunas está em `scripts_dados/dics/anp_combustiveis.md`.

## Etapas do pipeline

1. Verifica a disponibilidade dos pacotes R necessários.
2. Lê a página oficial da ANP e localiza os quatro CSVs esperados.
3. Baixa os arquivos para uma pasta temporária, com repetição automática em caso de falha transitória.
4. Lê os CSVs separados por ponto e vírgula em UTF-8 e seleciona as colunas necessárias.
5. Converte o ano para inteiro e mantém somente observações a partir de 2010.
6. Interrompe a execução se houver ano ausente/inválido ou linha integralmente duplicada após a seleção das colunas.
7. Normaliza os nomes municipais para fins de comparação: remove espaços excedentes, translitera acentos, converte para maiúsculas e remove caracteres não alfanuméricos.
8. Aplica tabelas explícitas de correções conferidas de nomes, códigos e localidades.
9. Reconcilia código, nome, UF e região com o `geobr` e interrompe a execução se restar divergência espacial.
10. Soma registros que passam a pertencer ao mesmo município–ano depois das correções, preservando `NA` quando todos os componentes são ausentes.
11. Para GLP, transforma `P13` e `OUTROS` do formato largo para o formato longo, criando `tipo_vasilhame` e `valor_kg`.
12. Valida a chave única de cada asset, grava os Parquets com compressão Snappy e, se `publicar = TRUE`, envia-os à release.
13. Depois de uma publicação bem-sucedida, tenta remover os assets antigos com sufixo `-tratado.parquet`.
14. Remove todo o diretório temporário ao encerrar, inclusive quando ocorre erro.

## Tratamento espacial

### Referência municipal

O script usa a malha cadastral de 2022 do `geobr`. O código da ANP é comparado primeiro pelos seis dígitos iniciais e depois conferido simultaneamente por nome normalizado e UF. Quando o código não identifica corretamente o município, o casamento é feito por nome normalizado dentro da UF.

Os campos finais `code_muni`, `name_muni`, `abbrev_state` e `name_region` seguem a referência do `geobr`; as grafias originais da ANP são apenas auxiliares do processo de reconciliação.

### Tabelas de correção explícitas

O script contém **54 regras de correspondência de nomes**: 47 correções de grafia, nome histórico ou renomeação municipal, mais 7 localidades incorporadas a seus municípios:

| localidade na ANP | UF | município de destino |
|---|---|---|
| Salobrinho | BA | Ilhéus |
| Monte Dourado | PA | Almeirim |
| Porto Trombetas | PA | Oriximiná |
| Paquequer Pequeno | RJ | Petrópolis |
| Retiro do Muriaé | RJ | Itaperuna |
| Rio dos Bugres | SC | Imbuia |
| Piramboia | SP | Anhembi |

Há ainda **5 correções explícitas de código**:

| código na ANP | UF | nome na ANP | código corrigido | motivo |
|---|---|---|---|---|
| `245306` | RN | Boa Saúde | `2405306` | zero ausente no código da ANP |
| `1700952` | TO | Ananás | `1701002` | código histórico incorreto |
| `1700952` | TO | Couto de Magalhães | `1706001` | código histórico incorreto |
| `1702750` | TO | Bernardo Sayão | `1703206` | código histórico incorreto |
| `1702750` | TO | São Valério da Natividade | `1720499` | código histórico incorreto |

Uma regra adicional preenche o nome de **Brasília (DF), código 5300108**, ausente em uma linha de GLP de 2012.

### Exclusões conferidas

Duas situações não são convertidas em municípios:

- **Fernando de Noronha (PE):** distrito estadual ausente da referência municipal adotada;
- **União (PR):** registro agregado que não permite identificar um município.

Na auditoria de 13/11/2026, essas regras retiraram 15 linhas da gasolina C, 15 do GLP e 16 do óleo diesel; o etanol não teve linha excluída. O resumo impresso pelo script conta regras distintas aplicadas, e não a quantidade bruta de linhas: respectivamente 0, 1, 1 e 2 regras nos quatro assets.

## Resultado da auditoria de 13/11/2026

A execução foi feita com `publicar = FALSE`, usando os arquivos então disponíveis na página da ANP.

| combustível | linhas finais | municípios distintos na série | municípios presentes por ano | combinações município/ano corrigidas | regras de exclusão aplicadas | `NA` na medida | negativos | zeros explícitos |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Etanol hidratado | 69.375 | 5.223 | 4.505–4.802 | 6.998 | 0 | 0 | 0 | 25 |
| Gasolina C | 81.607 | 5.527 | 5.342–5.513 | 0 | 1 | 0 | 0 | 1 |
| GLP | 134.536 | 5.197 | 4.078–4.800 | 61 | 1 | 0 | 43 | 20.833 |
| Óleo diesel | 81.793 | 5.538 | 5.385–5.509 | 0 | 2 | 0 | 0 | 0 |

No GLP há duas linhas por município–ano, uma para cada categoria de vasilhame. Por isso, a contagem de linhas não deve ser comparada diretamente à dos outros combustíveis. Depois da correção espacial, **7 grupos município–ano de GLP** foram consolidados por soma porque localidades/códigos passaram a apontar para a mesma unidade municipal.

As 6.998 e 61 correções da tabela são combinações município–ano afetadas, não 6.998 ou 61 municípios distintos. A contagem inclui casamentos refeitos por nome e UF e correções da tabela estática.

## Problemas, lacunas e cuidados de uso

### Ausência de município não é venda zero

Os assets não são painéis balanceados. Na extração auditada, por exemplo, o etanol apresentou de 4.505 a 4.802 municípios por ano, enquanto a gasolina C apresentou de 5.342 a 5.513. Município fora da tabela significa **ausência de registro publicado**, não volume igual a zero.

O pipeline não cria linhas para municípios ausentes. Em análises de médias, totais, participação ou crescimento, não substitua automaticamente essas ausências por zero.

### Repetição de 2017 no GLP de 2018

Na própria fonte da ANP, o GLP de 2018 repete exatamente municípios e valores de 2017. Desconsiderando a coluna de ano, são **9.046 linhas idênticas** no formato longo final. O pipeline preserva os dois anos porque ambos foram publicados pela fonte; comparações temporais devem tratar 2018 como um ano potencialmente copiado, e não como evidência de estabilidade real.

### Valores negativos de GLP

A auditoria encontrou **43 valores negativos** em `valor_kg`, todos oriundos da fonte:

| ano | categoria original | quantidade de valores negativos |
|---|---|---:|
| 2023 | `P13` | 4 |
| 2023 | `OUTROS` | 17 |
| 2024 | `P13` | 1 |
| 2024 | `OUTROS` | 21 |

Os menores valores observados foram −1.677 kg em `P13` e −17.276 kg em `OUTROS`. O script atual **não interrompe a execução, corrige nem transforma esses valores**. Eles permanecem no Parquet e precisam de decisão metodológica explícita antes de cálculos de total ou crescimento.

### Zeros explícitos

Zeros que aparecem na fonte são preservados. Na auditoria havia 25 no etanol, 1 na gasolina C e 20.833 linhas no GLP. Eles são diferentes de município–ano ausente e não devem ser confundidos com preenchimento artificial.

### Duplicatas

O script interrompe a execução se encontrar linha integralmente duplicada depois do recorte e da seleção das variáveis. Os quatro arquivos passaram nessa verificação em 13/11/2026. O código **não remove silenciosamente duplicatas**: uma nova ocorrência na fonte fará a execução falhar para revisão.

### Limites das validações atuais

O pipeline valida esquema, anos, duplicatas integrais, consistência territorial, divergências remanescentes e unicidade das chaves. Entretanto, ainda não:

- compara os totais finais com totais nacionais/estaduais publicados pela ANP;
- testa mudanças anormais de escala entre anos;
- exige cobertura mínima de municípios ou UFs por ano;
- barra valores negativos nas medidas;
- relê o Parquet gravado para confirmar esquema e conteúdo antes do upload.

Esses pontos não invalidam automaticamente os arquivos, mas delimitam o que foi efetivamente verificado. A presença dos 43 negativos de GLP demonstra por que não se deve presumir uma validação de domínio que o código ainda não executa.

### Fonte mutável

Os links diretos são descobertos em cada execução e a ANP pode substituir os CSVs mantendo os mesmos nomes. Assim, a auditoria de 13/11/2026 é um retrato da fonte naquele dia. Embora a extração tenha ocorrido em 2026, o último ano disponível nos quatro arquivos era 2024.

## Requisitos

### R e pacotes

É necessário ter R e os seguintes pacotes:

```r
install.packages(c(
  "arrow", "dplyr", "geobr", "httr", "purrr", "readr", "rvest",
  "stringr", "tibble", "tidyr", "xml2", "piggyback"
))
```

O pacote `piggyback` só é exigido quando `publicar = TRUE`.

### Acesso externo

A máquina precisa acessar:

- a página e os arquivos oficiais da ANP;
- os metadados usados por `geobr::lookup_muni()`;
- o GitHub, caso os assets sejam publicados.

### Token do GitHub

Para publicação, a variável de ambiente `GITHUB_PAT` deve conter um token com permissão para sobrescrever assets no repositório. O token não deve ser escrito no script nem versionado; use `.Renviron` ou `gitcreds`.

## Como executar

A partir da raiz do projeto:

```r
source(
  "scripts_dados/Dados_da_ANP/anp_combustiveis.R",
  encoding = "UTF-8"
)

# Auditoria local, sem upload:
rodar_pipeline_anp(publicar = FALSE)

# Geração e publicação na release data:
rodar_pipeline_anp(publicar = TRUE)
```

O script não é executado automaticamente ao ser carregado com `source()`. É necessário chamar `rodar_pipeline_anp()`.

## Publicação e arquivos temporários

Os CSVs e Parquets são criados dentro de um diretório temporário. Com `publicar = TRUE`, cada Parquet é enviado com sobrescrita para a release `data`. Em seguida, o script solicita a remoção dos quatro nomes antigos terminados em `-tratado.parquet`, evitando assets órfãos após a mudança de nomenclatura.

Com `publicar = FALSE`, os Parquets são gerados e validados, mas não são mantidos: o diretório temporário é apagado ao final. Esse modo serve para verificar o pipeline sem alterar a release.

## Critério para atualização desta documentação

Atualize este documento e o dicionário sempre que houver mudança de esquema, regra espacial, unidade, nome de asset, recorte temporal ou problema identificado na fonte. Em uma nova publicação, registre novamente a data de extração, as linhas, a cobertura municipal, as correções, as exclusões e as anomalias de domínio.
