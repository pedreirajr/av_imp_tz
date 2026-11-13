# Dicionário de dados — PIB municipal e PIB per capita

## Identificação da base

- **Asset publicado:** `pib_municipal_percapta.parquet`
- **Fonte:** IBGE, Produto Interno Bruto dos Municípios, base 2010–2023.
- **Nível de observação:** município × ano.
- **Chave única:** `ano` × `code_muni`.
- **Período:** 2010 a 2023.
- **Abrangência:** Brasil, 27 UFs; 5.565 municípios em 2010–2012 e 5.570 municípios em 2013–2023.
- **Formato:** Parquet com compressão Snappy.

## Correspondência DE-PARA e descrição das colunas

Os nomes da coluna **original** abaixo reproduzem o cabeçalho da planilha do IBGE depois de substituir quebras de linha e espaços repetidos por um espaço simples. O nome **final** é o campo gravado no Parquet.

| nome original no IBGE | nome final | tipo | unidade | descrição | valores possíveis e `NA` |
|---|---|---|---|---|---|
| `Ano` | `ano` | integer | ano | Ano de referência da observação. | Inteiros de 2010 a 2023; não admite `NA`. |
| `Código do Município` | `code_muni` | integer | código IBGE | Código municipal de sete dígitos, validado contra o `geobr`. | Código existente no `geobr`; não admite `NA`. |
| `Nome do Município` | `name_muni` | character | — | Nome oficial obtido do `geobr` depois da reconciliação espacial. | Nome municipal oficial; não admite `NA`. |
| `Valor adicionado bruto da Agropecuária, a preços correntes (R$ 1.000)` | `va_agro` | double | R$ 1.000 correntes | Valor adicionado bruto da agropecuária. | Número real; `NA` em 2022 e 2023 por não divulgação. |
| `Valor adicionado bruto da Indústria, a preços correntes (R$ 1.000)` | `va_ind` | double | R$ 1.000 correntes | Valor adicionado bruto da indústria. | Número real; `NA` em 2022 e 2023 por não divulgação. |
| `Valor adicionado bruto dos Serviços, a preços correntes - exceto Administração, defesa, educação e saúde públicas e seguridade social (R$ 1.000)` | `va_serv` | double | R$ 1.000 correntes | Valor adicionado bruto dos serviços, sem administração pública e seguridade social. | Número real; `NA` em 2022 e 2023 por não divulgação. |
| `Valor adicionado bruto da Administração, defesa, educação e saúde públicas e seguridade social, a preços correntes (R$ 1.000)` | `va_adm` | double | R$ 1.000 correntes | Valor adicionado bruto da administração pública, defesa, educação, saúde e seguridade social. | Número real; `NA` em 2022 e 2023 por não divulgação. |
| `Valor adicionado bruto total, a preços correntes (R$ 1.000)` | `va_total` | double | R$ 1.000 correntes | Soma dos quatro componentes de valor adicionado bruto, sujeita apenas ao arredondamento da fonte. | Número real; `NA` em 2022 e 2023 por não divulgação. |
| `Impostos, líquidos de subsídios, sobre produtos, a preços correntes (R$ 1.000)` | `impostos` | double | R$ 1.000 correntes | Impostos sobre produtos líquidos de subsídios. | Número real; pode ser negativo; `NA` em 2022 e 2023 por não divulgação. |
| `Produto Interno Bruto, a preços correntes (R$ 1.000)` | `pib` | double | R$ 1.000 correntes | Produto Interno Bruto municipal a preços correntes. | Número real; preenchido em todos os anos; pode ser negativo na fonte. |
| `Produto Interno Bruto per capita, a preços correntes (R$ 1,00)` | `pib_pc` | double | R$ correntes por habitante | Produto Interno Bruto por habitante a preços correntes. | Número real; preenchido em todos os anos; pode ser negativo na fonte. |
| `Atividade com maior valor adicionado bruto` | `ativ_1` | character | categoria de atividade | Atividade econômica com o maior valor adicionado bruto no município e ano. | Uma das dez categorias abaixo; `NA` em 2022 e 2023. |
| `Atividade com segundo maior valor adicionado bruto` | `ativ_2` | character | categoria de atividade | Atividade econômica com o segundo maior valor adicionado bruto. | Uma das dez categorias abaixo; `NA` em 2022 e 2023. |
| `Atividade com terceiro maior valor adicionado bruto` | `ativ_3` | character | categoria de atividade | Atividade econômica com o terceiro maior valor adicionado bruto. | Uma das dez categorias abaixo; `NA` em 2022 e 2023. |

## Categorias das atividades econômicas

Os campos `ativ_1`, `ativ_2` e `ativ_3` podem conter:

1. Administração, defesa, educação e saúde públicas e seguridade social;
2. Agricultura, inclusive apoio à agricultura e a pós colheita;
3. Comércio e reparação de veículos automotores e motocicletas;
4. Construção;
5. Demais serviços;
6. Eletricidade e gás, água, esgoto, atividades de gestão de resíduos e descontaminação;
7. Indústrias de transformação;
8. Indústrias extrativas;
9. Pecuária, inclusive apoio à pecuária;
10. Produção florestal, pesca e aquicultura.

## Significado de `NA`

`NA` significa **dado não divulgado**, nunca zero. Na edição 2010–2023, o IBGE não divulgou em 2022 e 2023 os seis campos de valor adicionado/impostos nem as três posições de atividade. Para esses dois anos, apenas `pib` e `pib_pc` estão preenchidos entre as medidas econômicas.

Os valores negativos existentes na fonte são preservados. Eles não representam ausência e não são convertidos para zero.
