# Manual do pipeline de PIB municipal e PIB per capita

## 1. Objetivo

O script `scripts_dados/Dados_do_IBGE/pib_municipal_percapta.R` baixa, valida, trata e publica a base municipal do Produto Interno Bruto do IBGE. O resultado tem uma linha por município e ano, de 2010 a 2023, e contém apenas os 14 campos definidos no dicionário.

O pipeline segue o padrão do repositório e a arquitetura do script da ANP: funções independentes para cada etapa, um orquestrador final, processamento em diretório temporário, validações que interrompem a execução e publicação opcional na release `data`.

## 2. Fonte e extração

- **Instituição:** Instituto Brasileiro de Geografia e Estatística (IBGE).
- **Produto:** Produto Interno Bruto dos Municípios, base de dados 2010–2023.
- **Página oficial:** <https://ftp.ibge.gov.br/Pib_Municipios/2022_2023/base/>
- **Arquivo oficial:** <https://ftp.ibge.gov.br/Pib_Municipios/2022_2023/base/base_de_dados_2010_2023_xlsx.zip>
- **Planilha lida:** `PIB dos Municípios`.
- **Data da inspeção técnica usada nesta documentação:** 13/11/2026.

O ZIP oficial contém um único `.xlsx`. O download usa `httr::RETRY()` com até cinco tentativas. Resposta HTTP diferente de 200, arquivo menor que 1 MB, ZIP inválido ou quantidade inesperada de planilhas interrompem o pipeline.

## 3. Saída

- **Asset:** `pib_municipal_percapta.parquet`.
- **Release:** tag `data` do repositório `pedreirajr/av_imp_tz`.
- **Formato:** Parquet, compressão Snappy.
- **Nível:** município × ano.
- **Chave:** `ano` × `code_muni`.
- **Cobertura:** 2010–2023, todas as 27 UFs.
- **Linhas esperadas:** 77.965.

A cobertura territorial esperada é de 5.565 municípios por ano em 2010–2012 e 5.570 municípios por ano em 2013–2023. A diferença decorre da instalação, em 2013, de Balneário Rincão (SC), Mojuí dos Campos (PA), Paraíso das Águas (MS), Pescaria Brava (SC) e Pinto Bandeira (RS).

## 4. Requisitos

### 4.1 Software e pacotes R

O script exige:

- `arrow`;
- `dplyr`;
- `geobr`;
- `httr`;
- `janitor`;
- `readr`;
- `readxl`;
- `sf`;
- `stringr`;
- `tibble`;
- `piggyback`, somente quando `publicar = TRUE`.

Os pacotes não são instalados automaticamente. A função `verificar_pacotes_pib()` lista dependências ausentes e encerra a execução.

### 4.2 Credencial para publicação

A publicação exige a variável de ambiente `GITHUB_PAT`, com permissão de escrita no repositório. O token deve ficar no `.Renviron` ignorado pelo Git ou ser configurado por `gitcreds`. O script nunca imprime o token.

## 5. Como executar

A partir da raiz do repositório:

```r
source(
  "scripts_dados/Dados_do_IBGE/pib_municipal_percapta.R",
  encoding = "UTF-8"
)

# Teste completo sem upload
rodar_pipeline_pib_municipal_percapta(publicar = FALSE)

# Processamento e publicação na release data
rodar_pipeline_pib_municipal_percapta(publicar = TRUE)
```

Todos os arquivos brutos e o Parquet são produzidos em um diretório temporário e removidos ao final, inclusive quando ocorre erro. Nenhum dado é gravado no diretóio versionado.

## 6. Etapas do pipeline

### 6.1 Verificação das dependências

`verificar_pacotes_pib()` confirma os namespaces necessários. `piggyback` só é exigido quando a publicação está ativa.

### 6.2 Download e descompactação

`baixar_base_pib()` baixa o ZIP oficial, valida o status HTTP, o tamanho mínimo, a integridade do arquivo e a existência de exatamente um `.xlsx`. O pipeline não continua com download parcial.

### 6.3 Leitura integral como texto

`ler_base_pib()` usa:

```r
readxl::read_excel(
  caminho_xlsx,
  sheet = "PIB dos Municípios",
  col_types = "text",
  na = "",
  trim_ws = FALSE,
  .name_repair = "minimal"
)
```

Assim, as 43 colunas entram como `character`, inclusive ano, códigos e medidas. A tipagem só ocorre depois da verificação do leiaute. Essa decisão evita inferência prematura, perda de códigos e conversão silenciosa de campos.

As quebras de linha e espaços repetidos dos cabeçalhos do Excel são normalizados. Em seguida, `janitor::clean_names()` produz nomes intermediários em `snake_case`. O DE-PARA manual transforma apenas os 14 campos finais nos nomes curtos documentados em `scripts_dados/dics/dicionario_pib.md`.

### 6.4 Tipagem controlada

`tipar_base_pib()` converte:

- `ano`, códigos de município, UF e região para `integer`;
- medidas monetárias para `double`;
- nomes e atividades para `character` normalizado.

Texto não vazio que não possa ser convertido para o tipo esperado causa erro com uma amostra dos valores problemáticos. Célula vazia continua como `NA`.

### 6.5 Reconciliação espacial com `geobr`

`obter_referencia_municipios_pib()` consulta a malha municipal de 2022 com `geobr::read_municipality()` e remove apenas a geometria antes das junções. Essa referência contém os mesmos 5.570 códigos territoriais da publicação, inclusive Fernando de Noronha. A base intermediária preserva e usa as colunas auxiliares do IBGE:

- código e nome da Grande Região;
- código, sigla e nome da Unidade da Federação;
- código e nome do município.

O casamento segue três níveis:

1. código, nome e campos auxiliares concordam;
2. se o código ou nome divergir, tenta-se nome normalizado mais UF e validam-se os demais campos auxiliares;
3. se o código e todos os campos auxiliares concordarem, o código é mantido e a grafia municipal é substituída pela do `geobr`.

Caso nenhum caminho produza casamento único e coerente, o script imprime uma amostra e para. O resultado sempre usa `code_muni` e `name_muni` do `geobr`; as colunas auxiliares servem para auditoria e são descartadas antes da modelagem final.

Na edição inspecionada, todos os 5.570 códigos e os campos de UF/região concordam com o `geobr`. Três nomes da planilha diferem da referência e são corrigidos em 42 registros município/ano:

| `code_muni` | nome na planilha | nome final do `geobr` |
|---:|---|---|
| 2802601 | Graccho Cardoso | Gracho Cardoso |
| 2932507 | Unas | Una |
| 3105509 | Barão do Monte Alto | Barão de Monte Alto |

Não foi necessário corrigir códigos na edição atual, mas o fluxo está preparado para corrigir um código quando nome, UF e região identificarem de forma inequívoca outro município.

### 6.6 Modelagem final

Depois da validação espacial, permanecem somente:

```text
ano, code_muni, name_muni,
va_agro, va_ind, va_serv, va_adm, va_total, impostos,
pib, pib_pc, ativ_1, ativ_2, ativ_3
```

A ordenação final é por `ano` e `code_muni`.

### 6.7 Validações de qualidade

`validar_base_pib()` interrompe a execução se ocorrer qualquer uma destas situações:

- esquema, ordem ou tipos diferentes do contrato;
- dataframe vazio;
- identificador ausente;
- `code_muni` fora do padrão de sete dígitos ou inexistente no `geobr`;
- chave `ano` × `code_muni` repetida;
- linha integralmente duplicada;
- cobertura anual diferente de 5.565/5.570 municípios;
- valor numérico infinito ou `NaN`;
- `NA` inesperado entre 2010 e 2021;
- padrão de ausências de 2022–2023 diferente do divulgado pelo IBGE;
- divergência superior a R$ 0,01 mil entre `va_total` e seus quatro componentes;
- divergência superior a R$ 0,01 mil entre `pib` e `va_total + impostos`;
- atividade econômica fora das dez categorias oficiais.

O Parquet é relido após a gravação e comparado ao dataframe em memória. O upload só ocorre depois dessa verificação.

### 6.8 Publicação

`publicar_parquet_pib()` envia o arquivo com `piggyback::pb_upload(overwrite = TRUE)` para a release existente `data`. O script não cria outra release e não oculta falhas de upload.

## 7. Resultados da auditoria da fonte

A planilha oficial inspecionada possui:

- 77.965 registros;
- 43 colunas brutas;
- 14 anos, de 2010 a 2023;
- 5.570 códigos municipais distintos;
- 27 UFs;
- zero duplicidades na chave `ano` × código municipal;
- 10 categorias de atividade econômica;
- fechamento dos agregados monetários com diferença máxima inferior a R$ 0,01 mil, compatível com arredondamento.

### 7.1 Ausências metodológicas

Em 2022 e 2023, para cada um dos 5.570 municípios, estão vazios:

- `va_agro`, `va_ind`, `va_serv`, `va_adm`, `va_total` e `impostos`;
- `ativ_1`, `ativ_2` e `ativ_3`.

Isso produz 100.260 `NA` esperados: 11.140 linhas × 9 campos. `pib` e `pib_pc` estão completos. O pipeline não imputa nem transforma essas ausências em zero.

### 7.2 Valores negativos

A fonte contém 113 células monetárias negativas entre 2010 e 2021:

| campo | células negativas |
|---|---:|
| `va_agro` | 1 |
| `va_ind` | 42 |
| `va_total` | 5 |
| `impostos` | 63 |
| `pib` | 1 |
| `pib_pc` | 1 |

Esses valores constam no arquivo oficial e são preservados. O caso mais importante para análise é Guamaré (RN), código 2404507, em 2012: `pib = -19046,434` em R$ 1.000 e `pib_pc = -1459,83` reais por habitante. Não se deve filtrar ou zerar automaticamente valores negativos.

## 8. Notas Metodológicas e Técnicas

### Notas Metodológicas

1. Os dados de 2022 e 2023 estarão sujeitos a revisão na próxima publicação.
2. Para os anos de 2022 e 2023 foram divulgados apenas o Produto Interno Bruto e o Produto Interno Bruto per capita, conforme a nota técnica 02/2024 do Sistema de Contas Nacionais ([https://biblioteca.ibge.gov.br/visualizacao/livros/liv102094.pdf](https://biblioteca.ibge.gov.br/visualizacao/livros/liv102094.pdf)).
3. O cálculo do PIB per capita de 2010 a 2021 considerou a população residente da Estatística Estimativa da População (data de referência em 1º de julho de cada ano). Para 2022 e 2023, devido à indisponibilidade destas estimativas, utilizou-se a população do Censo Demográfico 2022 (primeira apuração) e, para 2023, a Relação da População dos Municípios enviada ao TCU com atualizações de limites territoriais (até 30/04/2023).
4. Na seleção das atividades com maior valor adicionado bruto, a classe "Demais serviços" agrega: Transporte, armazenagem e correio; Alojamento e alimentação; Informação e comunicação; Atividades financeiras, de seguros e serviços relacionados; Atividades imobiliárias; Atividades profissionais, científicas e técnicas, administrativas e serviços complementares; Educação e saúde privadas; Artes, cultura, esporte e recreação e outras atividades de serviços e serviços domésticos.

### Cuidados técnicos para análise

- Os valores de `va_*`, `impostos` e `pib` estão em **R$ 1.000 correntes**. `pib_pc` está em **R$ correntes por habitante**. Não misture as escalas.
- Valores correntes não foram deflacionados. Comparações temporais de nível ou crescimento real exigem deflator adequado.
- `NA` em 2022–2023 significa não divulgação. Não significa atividade inexistente ou valor zero.
- Os dados de 2022–2023 são sujeitos a revisão e usam bases populacionais diferentes das estimativas anuais de 2010–2021.
- O ranking `ativ_1` a `ativ_3` está disponível somente até 2021.
- Nomes municipais seguem o `geobr` de 2022 para padronização transversal; o código IBGE é a chave recomendada para junções.

## 9. Dicionário de dados

O esquema final, o DE-PARA completo, tipos, unidades, categorias e significado de `NA` estão em `scripts_dados/dics/dicionario_pib.md`.

## 10. Solução de problemas

### Pacote ausente

Instale somente os pacotes listados na mensagem de erro e reinicie uma sessão limpa. O pipeline não instala dependências durante a execução.

### Falha de download

Confira conexão, proxy e disponibilidade do FTP do IBGE. O script tenta cinco vezes e para sem publicar se a falha persistir.

### Mudança no arquivo ou nos cabeçalhos

Se o IBGE substituir a edição 2010–2023, atualize `URL_ARQUIVO_PIB`, revise o DE-PARA e refaça as validações de cobertura e ausências. O erro de coluna ausente é deliberado para impedir publicação com esquema incorreto.

### Divergência espacial

O erro inclui até 20 combinações problemáticas. Confira código, nome, UF e região na fonte antes de criar qualquer regra excepcional. Não force casamento aproximado sem validação.

### `GITHUB_PAT` ausente

Use `publicar = FALSE` para testar transformação e validações. Configure o token antes do upload e nunca o inclua no script ou no Git.

## 11. Checklist antes da publicação

- executar em sessão R limpa a partir da raiz do projeto;
- testar com `publicar = FALSE`;
- confirmar 77.965 linhas e anos 2010–2023 no resumo;
- confirmar 5.565 municípios em 2010–2012 e 5.570 em 2013–2023;
- revisar a quantidade de correções espaciais;
- confirmar 100.260 ausências metodológicas e 113 valores negativos;
- configurar `GITHUB_PAT` sem imprimi-lo;
- executar com `publicar = TRUE`;
- conferir `pib_municipal_percapta.parquet` na release `data`.
