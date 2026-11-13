# Dicionário de dados — combustíveis da ANP

## Identificação da base

- **Script produtor:** `scripts_dados/Dados_da_ANP/anp_combustiveis.R`
- **Release:** `data`, no repositório `pedreirajr/av_imp_tz`
- **Recorte temporal:** 2010 a 2024 na extração auditada em 13/11/2026
- **Abrangência geográfica:** municípios brasileiros com registro de venda na fonte da ANP
- **Referência territorial:** `geobr::lookup_muni(year = 2022, name_muni = "all")`

O pipeline publica quatro assets:

| asset | conteúdo | nível da tabela | chave única | linhas na auditoria de 13/11/2026 |
|---|---|---|---|---:|
| `vendas-anuais-de-etanol-hidratado-por-municipio.parquet` | vendas anuais de etanol hidratado | município × ano | `code_muni`, `ano` | 69.375 |
| `vendas-anuais-de-gasolina-c-por-municipio.parquet` | vendas anuais de gasolina C | município × ano | `code_muni`, `ano` | 81.607 |
| `vendas-anuais-de-glp-por-municipio.parquet` | vendas anuais de GLP por tipo de vasilhame | município × ano × tipo de vasilhame | `code_muni`, `ano`, `tipo_vasilhame` | 134.536 |
| `vendas-anuais-de-oleo-diesel-por-municipio.parquet` | vendas anuais de óleo diesel | município × ano | `code_muni`, `ano` | 81.793 |

> A ausência de uma combinação município–ano não significa venda igual a zero. A ANP publica apenas municípios com registro. O pipeline não completa o painel com zeros.

## Colunas dos assets de etanol, gasolina C e óleo diesel

| coluna | tipo | unidade | descrição | valores possíveis | significado de `NA` |
|---|---|---|---|---|---|
| `ano` | `integer` | ano | Ano de referência da venda. | Inteiros de 2010 a 2024 na extração auditada. | Não permitido pelo pipeline. |
| `code_muni` | `integer` | — | Código IBGE de sete dígitos do município, reconciliado com o `geobr`. | Código municipal válido na referência territorial de 2022. | Não permitido pelo pipeline. |
| `name_muni` | `character` | — | Nome oficial do município obtido do `geobr`, e não a grafia original da ANP. | Nomes presentes na referência municipal do `geobr`. | Não permitido pelo pipeline. |
| `abbrev_state` | `character` | — | Sigla da Unidade da Federação obtida/validada com o `geobr`. | `AC`, `AL`, `AP`, `AM`, `BA`, `CE`, `DF`, `ES`, `GO`, `MA`, `MT`, `MS`, `MG`, `PA`, `PB`, `PR`, `PE`, `PI`, `RJ`, `RN`, `RS`, `RO`, `RR`, `SC`, `SP`, `SE`, `TO`. | Não permitido pelo pipeline. |
| `name_region` | `character` | — | Nome da macrorregião do município segundo o `geobr`. | Norte, Nordeste, Sudeste, Sul e Centro Oeste. | Não permitido pelo pipeline. |
| `vendas_litros` | `double` | litros | Volume anual vendido do combustível correspondente ao asset. Vem da coluna `VENDAS` da ANP. | Número real; zeros explícitos da fonte são preservados. | Indica medida ausente na fonte. Na extração auditada não havia `NA` nesta coluna. Município–ano sem linha na fonte permanece ausente da tabela, e não como `NA` ou zero. |

## Colunas do asset de GLP

| coluna | tipo | unidade | descrição | valores possíveis | significado de `NA` |
|---|---|---|---|---|---|
| `ano` | `integer` | ano | Ano de referência da venda. | Inteiros de 2010 a 2024 na extração auditada. | Não permitido pelo pipeline. |
| `code_muni` | `integer` | — | Código IBGE de sete dígitos do município, reconciliado com o `geobr`. | Código municipal válido na referência territorial de 2022. | Não permitido pelo pipeline. |
| `name_muni` | `character` | — | Nome oficial do município obtido do `geobr`. | Nomes presentes na referência municipal do `geobr`. | Não permitido pelo pipeline. |
| `abbrev_state` | `character` | — | Sigla da Unidade da Federação obtida/validada com o `geobr`. | As 27 siglas de UF, incluindo `DF`. | Não permitido pelo pipeline. |
| `name_region` | `character` | — | Nome da macrorregião do município segundo o `geobr`. | Norte, Nordeste, Sudeste, Sul e Centro Oeste. | Não permitido pelo pipeline. |
| `tipo_vasilhame` | `character` | — | Categoria de acondicionamento do GLP. | `vendas_vasilhames_p13_kg`: botijões P13; `vendas_vasilhames_outros_kg`: demais vasilhames. | Não permitido pelo pipeline. |
| `valor_kg` | `double` | quilogramas | Quantidade anual vendida de GLP na categoria indicada por `tipo_vasilhame`. | Número real; zeros e valores negativos existentes na fonte são preservados. | Indica medida ausente na fonte. Na extração auditada não havia `NA`; município–ano ausente não é criado artificialmente. |

## Correspondência entre a fonte e a saída

| coluna/campo na ANP | coluna/campo final | tratamento |
|---|---|---|
| `ANO` | `ano` | Conversão para inteiro e filtro para `ano >= 2010`. |
| `CÓDIGO IBGE` | `code_muni` | Tratado inicialmente como texto, corrigido quando necessário e substituído pelo código de sete dígitos validado no `geobr`. |
| `MUNICÍPIO` | `name_muni` | Usado na reconciliação espacial; a saída recebe o nome oficial do `geobr`. |
| `UF` | `abbrev_state` | Usado na reconciliação; a saída é validada contra a referência territorial. |
| `GRANDE REGIÃO` | `name_region` | Usado como informação auxiliar; a saída recebe a região associada ao município no `geobr`. |
| `VENDAS` | `vendas_litros` | Renomeação nos assets de etanol, gasolina C e óleo diesel. |
| `P13` | `tipo_vasilhame = "vendas_vasilhames_p13_kg"`, `valor_kg` | A coluna larga é convertida em categoria e valor no formato longo. |
| `OUTROS` | `tipo_vasilhame = "vendas_vasilhames_outros_kg"`, `valor_kg` | A coluna larga é convertida em categoria e valor no formato longo. |

## Regras de interpretação

1. Uma linha ausente não deve ser transformada em zero sem justificativa externa.
2. Zeros presentes em `vendas_litros` ou `valor_kg` são registros explícitos da fonte.
3. Os quatro assets não formam painéis balanceados: a quantidade de municípios varia entre combustíveis e anos.
4. Os valores negativos de GLP são mantidos exatamente como publicados; consulte a documentação do pipeline antes de agregá-los ou recodificá-los.
5. O GLP possui duas linhas por município–ano quando as duas categorias de vasilhame estão presentes. Para obter o total municipal, agregue `valor_kg` sobre `tipo_vasilhame`, preservando a política de tratamento de ausências escolhida na análise.
