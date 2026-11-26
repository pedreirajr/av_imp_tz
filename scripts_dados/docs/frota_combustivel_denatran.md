# Extração da frota de veículos por município e tipo de combustível

O script `scripts_dados/frota_combustivel_denatran.R` monta um painel mensal da frota de veículos por município e tipo de combustível. Os dados vêm direto das planilhas publicadas pela SENATRAN (RENAVAM). O resultado é gravado em Parquet e publicado como asset da release `data` do repositório.

Ele é bem diferente do [`frota_denatran.R`](frota_denatran.md). Lá, a Base dos Dados entrega a frota por tipo de veículo já tratada, com código IBGE, e o script é basicamente uma consulta SQL. **O recorte por combustível não existe na Base dos Dados**: o dataset `br_denatran_frota` só tem as tabelas `municipio_tipo` e `uf_tipo`. Por isso este script faz sozinho todo o trabalho que a Base dos Dados faria. Ele raspa o site da SENATRAN, baixa os arquivos mês a mês, lida com formatos diferentes, casa os nomes dos municípios com o código IBGE e corrige erros da própria fonte.

Esta documentação descreve o comportamento do script e os resultados da auditoria da execução de **26/11/2026**, a mesma que publicou o asset. Como a SENATRAN publica um mês novo por vez, o mês final e as contagens devem ser conferidos de novo a cada publicação.

---

## Fonte dos dados

- **Órgão:** Secretaria Nacional de Trânsito (SENATRAN), Ministério dos Transportes. Os dados vêm do RENAVAM.
- **Páginas:** uma por ano, no padrão `https://www.gov.br/transportes/pt-br/assuntos/transito/conteudo-Senatran/frota-de-veiculos-AAAA` (ex.: [2026](https://www.gov.br/transportes/pt-br/assuntos/transito/conteudo-Senatran/frota-de-veiculos-2026)).
- **Arquivo usado:** em cada mês, na seção *"Quantidade de Veículos por Município"*, o arquivo *"Frota por UF, Município e Combustível"*.
- **Códigos IBGE:** [API de localidades do IBGE](https://servicodados.ibge.gov.br/api/v1/localidades/municipios), consultada a cada execução.

---

## O que o script faz

1. **Lista os arquivos.** Baixa o HTML de cada página anual, de `ANO_INICIAL` até o ano corrente, e guarda os links de download que contêm "combust".
2. **Identifica o mês de cada link.** Os nomes dos arquivos não seguem padrão, então o mês é inferido da URL. Se algum link ficar sem mês, o script para com erro.
3. **Baixa e lê cada mês.** Lê `.xlsx`/`.xls` direto e descompacta antes os `.zip`/`.rar`. Pega sempre as 4 primeiras colunas da primeira aba: UF, Município, Combustível e Quantidade.
4. **Aplica as correções de erros da fonte** (ver [Erros da fonte corrigidos](#erros-da-fonte-corrigidos)).
5. **Limpa os textos.** Corrige o encoding quebrado e normaliza nomes de UF, município e combustível.
6. **Casa com o código IBGE** pelo par (UF, município), usando a lista oficial do IBGE e um de-para manual (`CROSSWALK`).
7. **Descarta o que não é município**, como linhas de total e "Sem Informação".
8. **Pivota para o formato wide.** Fica uma linha por município × mês e uma coluna por combustível; combustível ausente vira 0.
9. **Grava e publica.** Salva o Parquet em `tempdir()` e, se `PUBLICAR <- TRUE`, envia para a release com `piggyback`.

---

## Requisitos

### Pacotes R

```r
install.packages(c("httr", "readxl", "dplyr", "tidyr", "stringi",
                   "jsonlite", "arrow", "piggyback", "archive"))
```

O pacote **`archive`** é necessário para os meses distribuídos em `.zip`/`.rar`, que são vários de 2015 e 2016. No Windows e no macOS ele instala direto do CRAN. **No Linux** ele precisa da biblioteca de sistema `libarchive`:

```bash
sudo apt install libarchive-dev   # Debian/Ubuntu
```

Sem o `archive`, o script para quando chega no primeiro `.rar`, com a mensagem `Instale o pacote 'archive'...`.

### Token do GitHub

O processo é o mesmo dos outros scripts: um Personal Access Token com escopo `repo` na variável `GITHUB_PAT`, definida no `.Renviron` da raiz do projeto. Esse arquivo está no `.gitignore`. O token só é necessário com `PUBLICAR <- TRUE`.

### Acesso à internet

Não é preciso conta no Google Cloud. O script faz cerca de 170 requisições: 13 páginas anuais, mais de 150 planilhas (cerca de 1 MB cada) e a API do IBGE. A execução completa leva alguns minutos.

---

## Configuração

| Variável | Descrição | Valor atual |
|---|---|---|
| `ANO_INICIAL` | Primeiro ano raspado | `2014` |
| `ANO_FINAL` | Último ano raspado | ano corrente (`Sys.Date()`) |
| `PUBLICAR` | `TRUE` envia o Parquet para a release; `FALSE` só gera o arquivo | `TRUE` |
| `REPO` | Repositório da release | `"pedreirajr/av_imp_tz"` |
| `TAG` | Tag da release (precisa já existir) | `"data"` |
| `CROSSWALK` | De-para manual de nomes da SENATRAN para código IBGE (43 entradas) | — |
| `NAO_MUNICIPIO` | Valores de UF/município descartados | "Sem Informação", "Não Identificado", "Não se Aplica", "Sem Combustível" |

Para testar sem publicar, mude `PUBLICAR <- FALSE`.

---

## Como rodar

```r
source("scripts_dados/frota_combustivel_denatran.R", encoding = "UTF-8")
```

Durante a execução, o script imprime o progresso de cada mês (`[i/N] AAAA-MM`). No final, mostra as categorias de combustível encontradas e o tamanho do painel.

Para guardar uma cópia local, além da release:

```r
file.copy(arquivo_saida, "data/processed/frota_combustivel_mensal_municipio.parquet")
```

---

## Saída

| Asset | Descrição |
|---|---|
| `frota_combustivel_mensal_municipio.parquet` | Painel mensal da frota por município e combustível, de jan/2014 até o último mês publicado pela SENATRAN |

Para usar em outro script:

```r
piggyback::pb_download("frota_combustivel_mensal_municipio.parquet",
                       repo = "pedreirajr/av_imp_tz", tag = "data")
```

### Estrutura das colunas

As colunas de identificação seguem a mesma convenção do `frota_denatran.R` (padrão `geobr`), então os dois painéis podem ser cruzados por `code_muni`, `ano` e `mes`.

| Coluna | Tipo | Descrição |
|---|---|---|
| `code_muni` | texto | Código IBGE de 7 dígitos |
| `name_muni` | texto | Nome do município **segundo o IBGE atual** (não o nome da planilha) |
| `abbrev_state` | texto | Sigla da UF |
| `ano` | inteiro | Ano de referência |
| `mes` | inteiro | Mês de referência |
| *(uma coluna por combustível)* | numérico | Quantidade de veículos com aquele combustível |

Os nomes das colunas de combustível são as categorias da SENATRAN em minúsculas, sem acento e com `_` no lugar de caracteres especiais. Por exemplo, `ALCOOL/GASOLINA` vira `alcool_gasolina` e `HIBRIDO PLUG-IN` vira `hibrido_plug_in`.

### Categorias de combustível

O painel publicado tem 29 categorias. Muitas só passaram a existir na fonte em algum momento da série:

| Categoria | Desde | Frota em set/2026 | Observação |
|---|---|---:|---|
| `alcool_gasolina` | 01/2014 | 58.251.047 | flex |
| `gasolina` | 01/2014 | 52.229.923 | |
| `diesel` | 01/2014 | 10.464.181 | |
| `sem_informacao` | 01/2014 | 4.498.120 | combustível não informado |
| `alcool` | 01/2014 | 4.160.254 | |
| `gasolina_alcool_gas_natural` | 01/2014 | 1.276.544 | |
| `gasolina_gas_natural_veicular` | 01/2014 | 1.163.620 | |
| `gasolina_eletrico` | 01/2014 | 380.350 | |
| `eletrico_fonte_externa` | 01/2014 | 332.025 | |
| `gasolina_alcool_eletrico` | 09/2019 | 275.917 | |
| `alcool_gas_natural_veicular` | 01/2014 | 91.136 | |
| `hibrido_plug_in` | 04/2022 | 79.245 | |
| `hibrido` | 03/2023 | 40.272 | |
| `eletrico` | 10/2022 | 36.787 | |
| `eletrico_fonte_interna` | 01/2014 | 26.320 | |
| `diesel_eletrico` | 03/2021 | 13.155 | |
| `gas_natural_liquefeito` | 12/2019 | 56 | |
| `celula_combustivel` | 12/2022 | 13 | |
| `etanol_eletrico` | 03/2022 | 2 | |
| `hibrido_gas_natural_veicular` | 09/2023 | 1 | |
| *demais* (`gas_metano`, `gasogenio`, `gas_natural_veicular`, `vide_campo_observacao`, `nao_identificado`, ...) | 01/2014 | < 10 mil cada | residuais |

> **Atenção:** antes da data em "Desde", o valor da categoria é **0 porque ela não existia na classificação da fonte**. Isso não quer dizer que não havia veículos daquele tipo. Elétricos e híbridos, por exemplo, provavelmente estavam classificados em `eletrico_fonte_externa`, `gasolina_eletrico` etc. Para análises temporais, é recomendável **agrupar as categorias** (por exemplo: fóssil, flex, elétrico/híbrido, outros) em vez de usar as colunas originais isoladamente.

---

## Erros da fonte corrigidos

Estes problemas estão **nos arquivos publicados pela SENATRAN**, não na extração. Foram encontrados comparando o total por município/mês com a frota por tipo do `frota_denatran.R`, que deve somar o mesmo valor. Cada correção é aplicada explicitamente no script, no bloco "correções da fonte".

| Mês | Problema na fonte | Tratamento |
|---|---|---|
| **nov/2021** | Todas as quantidades vêm multiplicadas por 10: todos os valores terminam em 0, e o total nacional fica em 1,11 bilhão de veículos | Valores divididos por 10. Depois disso, o total (111.109.129) bate com a frota por tipo do mesmo mês (111.109.131) |
| **dez/2021** | O arquivo publicado é idêntico ao de jan/2022, inclusive no total (111.677.738, igual à frota por tipo de jan/2022 e diferente da de dez/2021, que é 111.446.867) | **Mês descartado.** A série tem um buraco em dez/2021 |
| **jan/2018** | A categoria "Sem Informação" vem rotulada como "SEM COMBUSTIVEL" | Unificada em `sem_informacao`. A série fica contínua (2,69 mi em dez/2017, 2,70 mi em jan/2018, 2,71 mi em fev/2018) |
| **ago e set/2019** | A linha de cabeçalho aparece repetida dentro da planilha | Descartada, porque não tem quantidade numérica |
| vários anos | Acentuação quebrada (ex.: "Sem InformaÃ§Ã£o"), o que geraria colunas duplicadas | Corrigida pela função `corrige_encoding()` |

---

## Casamento com o código IBGE

Este é o ponto mais delicado do script. **As planilhas não trazem código IBGE**, só o nome da UF por extenso e o nome do município em maiúsculas e sem acento (ex.: `MINAS GERAIS`, `GOUVEA`).

O casamento funciona assim:

1. O script baixa a lista atual de municípios da API do IBGE.
2. Cria uma chave `UF|MUNICÍPIO` normalizada dos dois lados: maiúsculas, sem acento, e hífen e apóstrofo trocados por espaço. Assim, "Mogi-Guaçu" e "MOGI GUACU" ficam iguais, assim como "São Miguel d'Oeste" e "SAO MIGUEL D OESTE".
3. Os nomes que mesmo assim não batem vão para o `CROSSWALK`, com o código IBGE escrito à mão. São 43 entradas, de três tipos:
   - **Grafia antiga ou diferente:** Parati → Paraty, Gouvea → Gouveia, Embu → Embu das Artes, Brasopolis → Brazópolis etc.
   - **Município renomeado:** Campo de Santana → Tacima (PB), Santarém → Joca Claudino (PB), Boa Saúde → Januário Cicco (RN), Fortaleza do Tabocão → Tabocão (TO), São Valério da Natividade → São Valério (TO), Governador Edison Lobão → Ribeirãozinho do Maranhão (MA).
   - **Distrito:** Ibitiúva, distrito de Pitangueiras/SP, que é somado ao município.
4. **Se algum nome ficar sem código, o script para com erro** e lista os nomes que precisam entrar no `CROSSWALK`. Isso é intencional: um aviso deixaria passar um painel faltando município sem ninguém perceber.

---

## Validação (execução de 26/11/2026)

| Verificação | Resultado |
|---|---|
| Linhas × colunas | 852.226 × 34 (5 de identificação + 29 de combustível) |
| Período | 01/2014 a 10/2026: 153 meses (154 publicados, menos dez/2021) |
| Municípios | 5.571 (5.570 por mês até jun/2025; 5.571 a partir de jul/2025) |
| Duplicatas de `code_muni` × `ano` × `mes` | 0 |
| `NA`, negativos ou valores não inteiros | 0 |
| Consistência de código/UF/nome | um nome e uma UF por código; prefixo do código coerente com a UF |
| Continuidade do total nacional | cresce entre 0,1% e 0,6% ao mês, sem saltos |
| Conferência célula a célula contra as planilhas originais (jun/2015 em `.rar`, abr/2017, nov/2021, mar/2024, set/2026) | **0 diferenças** em ~230 mil células; totais por combustível idênticos |
| Total por município/mês × frota por tipo (`frota_mensal_municipio.parquet`) | 97,6% dos pares idênticos; só 0,06% com diferença acima de 1% |

---

## Limitações

### A série começa em 2014, não em 2006

O `frota_denatran.R` vai de 2006 em diante, mas este painel **começa em jan/2014**:

- A SENATRAN só publica a frota por combustível a partir de **mai/2013**. Não há páginas de 2006 a 2012.
- Os 8 meses de 2013 vêm em **Microsoft Access** (`.mdb`/`.accdb`), formato que não tem leitor portátil em R (exigiria `mdbtools` ou ODBC, que variam por sistema). Por isso foram deixados de fora.

Ao cruzar com a frota por tipo, o período comum é **2014 em diante**.

### Buraco em dez/2021

O mês foi descartado porque a fonte publicou dados errados (ver acima). Quem precisar de série contínua pode interpolar, ou usar nov/2021 ou jan/2022 como aproximação, sempre deixando isso explícito na análise.

### Categorias mudam ao longo do tempo

A SENATRAN criou categorias novas ao longo da série (`hibrido`, `hibrido_plug_in`, `eletrico`, `celula_combustivel`, `gasolina_alcool_eletrico`...) sem reclassificar o histórico. Comparações diretas de uma coluna entre anos podem refletir **mudança de classificação, e não mudança real da frota**. O script não agrupa as categorias; essa decisão fica para a análise.

### Veículos sem município ficam de fora

Cerca de **2% a 3% da frota nacional** aparece na fonte com UF "Sem Informação" e é descartada, porque não é possível atribuí-la a um município. Em jun/2015 foram 2,4 milhões de veículos (2,6%), e em set/2026, 3,1 milhões (2,3%). A frota por tipo tem o mesmo comportamento, e os totais dos dois painéis batem. Mas a **soma dos municípios não é igual ao total do Brasil** publicado pela SENATRAN.

### Nomes de município seguem o IBGE atual

`name_muni` vem da API do IBGE no momento da execução, então municípios renomeados aparecem com o nome atual em toda a série. Já o código (`code_muni`) é estável.

### Municípios criados durante a série

Boa Esperança do Norte (MT, 5101837) só aparece a partir de jul/2025, quando passou a existir na fonte. Antes disso, a frota dele estava contada no(s) município(s) de origem. O painel não é retroativamente ajustado.

---

## Obstáculos e fragilidades

### Depende do HTML do site da SENATRAN

O script não usa uma API: ele lê o HTML das páginas e procura os links. Se a SENATRAN mudar a estrutura do site, o endereço das páginas anuais (`frota-de-veiculos-AAAA`) ou o texto dos links (que hoje contêm "combust"), a raspagem pode **não encontrar os arquivos ou encontrar arquivos errados**. Algumas peculiaridades já observadas:

- a página de 2014 é a primeira do índice oficial, e a de 2013 existe, mas não aparece no índice;
- links de 2020 apontam para outra área do site (`centrais-de-conteudo/...-xlsx`, sem extensão de arquivo);
- alguns arquivos de 2026 ficam fora da pasta do ano, e um deles tem prefixo `copy_of_`.

### Nomes de arquivos sem padrão

Cada ano (às vezes cada mês) usa uma convenção diferente:

```
3quantidadeveiculosufmunicipiocombustivel.zip            (2013, sem mês no nome)
3_frotaporufmunicipiocombustivel_abr2014.xlsx
3_frota_por_uf_municipio_combustivel_jun_2015.rar
3_-_combustivel_-_abril_-_2017.xlsx
d_frota_por_uf_municipio_combustivel_dezembro_2018.xlsx
D_Frota_por_UF_Municipio_COMBUSTIVEL_Maro_2026.xlsx      ("Março" sem o ç)
```

A função `mes_da_url()` tenta, nesta ordem: a pasta da URL (`/2018/dezembro/`), o nome completo do mês e a abreviação (inclusive colada ao ano, como `abr2014`). Um padrão novo pode exigir ajuste nessa função. Se isso acontecer, o script para com erro em vez de atribuir o mês errado.

### Formatos variados

| Período | Formato | Situação |
|---|---|---|
| 2013 | `.mdb`/`.accdb` dentro de `.zip`/`.rar` | ignorado |
| 2014 | `.xlsx` e um `.xls` | lido |
| 2015–2016 | `.rar` com `.xlsx` dentro (18 meses: todo 2015 e 6 de 2016) | lido via `archive` |
| 2017–2026 | `.xlsx` | lido |

Por sorte, o **layout interno é o mesmo** em todos os anos (4 colunas), mas o nome das abas (`COMBUSTIVEL`, `Layout D`, `Plan1`...) e o texto dos cabeçalhos ("Combustível Veículo", "Combustão veículo") mudam. Por isso o script lê sempre a primeira aba e as 4 primeiras colunas por posição, sem depender dos nomes.

### Dependência do pacote `archive` no Linux

O `archive` exige a biblioteca de sistema `libarchive` (`libarchive-dev`), que precisa de permissão de administrador para instalar. Em máquinas sem essa biblioteca, o script não consegue ler os meses de 2015–2016.

### Casamento por nome é frágil a renomeações

Como o casamento é feito por nome, **qualquer município renomeado pelo IBGE quebra o casamento**, porque a SENATRAN costuma manter o nome antigo. Isso já aconteceu durante o desenvolvimento: o IBGE passou a chamar Governador Edison Lobão (MA) de Ribeirãozinho do Maranhão, e o município sumia da série inteira. Agora o script para com erro nesses casos. A solução é acrescentar a linha correspondente ao `CROSSWALK` e rodar de novo.

### Novos erros da fonte não são detectados automaticamente

As correções de nov/2021, dez/2021 e jan/2018 estão **fixas no código** e foram encontradas por conferência manual. Um erro semelhante num mês futuro (valores multiplicados, arquivo repetido, categoria renomeada) **não é detectado pelo script**. A cada nova publicação, recomenda-se repetir pelo menos estas checagens:

- o total nacional por mês deve crescer de forma suave (cerca de 0,3% ao mês);
- o total por município/mês deve bater com a frota por tipo do `frota_denatran.R`;
- nenhuma categoria nova "suspeita" deve aparecer na lista impressa ao final da execução.

---

## Publicação na release

Com `PUBLICAR <- TRUE`, o final do script envia o Parquet com:

```r
pb_upload(file = arquivo_saida, repo = REPO, tag = TAG, overwrite = TRUE)
```

O `overwrite = TRUE` faz cada execução substituir o asset anterior. O script não cria a release; a tag `data` precisa já existir.

Logo depois do upload, o `piggyback::pb_list()` pode demorar a mostrar o arquivo novo. Para confirmar que ele está lá, consulte a [página da release](https://github.com/pedreirajr/av_imp_tz/releases/tag/data) ou rode `gh release view data -R pedreirajr/av_imp_tz`.
