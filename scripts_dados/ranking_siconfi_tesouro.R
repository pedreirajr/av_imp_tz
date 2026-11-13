# Fonte: Ranking da Qualidade da Informação Contábil e Fiscal no Siconfi (STN)
# Página: https://ranking-municipios.tesouro.gov.br/
# Download direto: https://ranking-municipios.tesouro.gov.br/static/data/down_loads/municipios_bspn.zip

library(dplyr)
library(readr)
library(httr)
library(geobr)
library(arrow)
library(piggyback)

url_dados <- "https://ranking-municipios.tesouro.gov.br/static/data/down_loads/municipios_bspn.zip"
dir_temp <- file.path(tempdir(), "siconfi_bspn")
dir.create(dir_temp, showWarnings = FALSE, recursive = TRUE)
arquivo_zip <- file.path(dir_temp, "municipios_bspn.zip")

# Download com retentativas para lidar com instabilidades do servidor gov.br
sucesso_download <- FALSE
for (tentativa in 1:5) {
  resp <- tryCatch(
    GET(
      url_dados,
      write_disk(arquivo_zip, overwrite = TRUE),
      timeout(120)
    ),
    error = function(e) NULL
  )
  if (!is.null(resp) && status_code(resp) == 200 && file.exists(arquivo_zip) && file.size(arquivo_zip) > 0) {
    sucesso_download <- TRUE
    break
  }
  Sys.sleep(5 * tentativa)
}

if (!sucesso_download) {
  stop("Falha ao baixar o arquivo ZIP do Ranking Siconfi após 5 tentativas.")
}

arquivos_extraidos <- unzip(arquivo_zip, exdir = dir_temp)
arquivo_csv <- arquivos_extraidos[grepl("\\.csv$", arquivos_extraidos, ignore.case = TRUE)][1]

if (is.na(arquivo_csv) || !file.exists(arquivo_csv)) {
  stop("Nenhum arquivo CSV encontrado dentro do ZIP extraído.")
}

# Leitura apenas das colunas necessárias
dados_brutos <- read_delim(
  arquivo_csv,
  delim = ";",
  locale = locale(decimal_mark = ",", grouping_mark = ".", encoding = "UTF-8"),
  col_select = c(exercicio, Ente, per_acertos),
  show_col_types = FALSE
)

# Referência oficial de municípios no padrão geobr
muni_geobr <- read_municipality(year = 2022, simplified = TRUE, showProgress = FALSE) |>
  sf::st_drop_geometry() |>
  transmute(
    code_muni = as.integer(code_muni),
    name_muni = as.character(name_muni),
    abbrev_state = as.character(abbrev_state),
    code_state = as.integer(code_state)
  )

# Tratamento e padronização
dados_tratados <- dados_brutos |>
  transmute(
    code_muni = as.integer(Ente),
    ano = as.integer(exercicio),
    per_acertos = as.numeric(per_acertos)
  ) |>
  filter(!is.na(code_muni), !is.na(ano)) |>
  distinct()

# Checagem de existência dos códigos IBGE no geobr antes do join
codigos_invalidos <- setdiff(unique(dados_tratados$code_muni), muni_geobr$code_muni)
if (length(codigos_invalidos) > 0) {
  stop(paste(
    "Foram encontrados códigos IBGE inexistentes no geobr:",
    paste(codigos_invalidos, collapse = ", ")
  ))
}

dados_finais <- dados_tratados |>
  inner_join(muni_geobr, by = "code_muni") |>
  select(
    code_muni,
    name_muni,
    abbrev_state,
    code_state,
    ano,
    per_acertos
  ) |>
  arrange(ano, code_muni)

# Checagens obrigatórias antes de publicar
stopifnot(
  "Tabela final está vazia" = nrow(dados_finais) > 0,
  "Existem linhas duplicadas na chave code_muni x ano" = nrow(dados_finais) == nrow(distinct(dados_finais, code_muni, ano)),
  "Existem valores NA nos identificadores" = !any(is.na(dados_finais$code_muni) | is.na(dados_finais$name_muni) | is.na(dados_finais$abbrev_state) | is.na(dados_finais$code_state) | is.na(dados_finais$ano)),
  "Valores de per_acertos fora do intervalo esperado [0, 1]" = all(dados_finais$per_acertos >= 0 & dados_finais$per_acertos <= 1, na.rm = TRUE),
  "Total de linhas não confere com a base bruta filtrada" = nrow(dados_finais) == nrow(dados_tratados),
  "Nem todas as 26 UFs (excluindo DF) estão presentes" = length(unique(dados_finais$abbrev_state)) >= 26,
  "Ano inicial esperado (2019) ausente" = 2019L %in% dados_finais$ano
)

# Publicação na release 'data'
arquivo_parquet <- file.path(tempdir(), "ranking_siconfi_municipio.parquet")
write_parquet(dados_finais, arquivo_parquet)

pb_upload(
  file = arquivo_parquet,
  repo = "pedreirajr/av_imp_tz",
  tag = "data",
  overwrite = TRUE
)

# Limpeza dos arquivos temporários
unlink(arquivo_parquet)
unlink(dir_temp, recursive = TRUE)