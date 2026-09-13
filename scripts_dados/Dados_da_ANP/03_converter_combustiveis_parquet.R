# Converte os CSVs tratados da ANP em arquivos Parquet para o repositorio.
# Execute com o diretorio de trabalho em scripts_dados/Dados_da_ANP/:
# source("03_converter_combustiveis_parquet.R", encoding = "UTF-8")

pacotes <- c("readr", "arrow")
faltando <- pacotes[!vapply(pacotes, requireNamespace, logical(1), quietly = TRUE)]
if (length(faltando)) {
  install.packages(faltando, repos = "https://cloud.r-project.org")
}


DIR_CSV_TRATADOS <-"data"
DIR_PARQUET <-"parquet"

if (!dir.exists(DIR_CSV_TRATADOS)) {
  stop(
    "Pasta dos CSVs tratados nao encontrada: ", normalizePath(DIR_CSV_TRATADOS, winslash = "/", mustWork = FALSE),
    "\nAbra o projeto av_imp_tz antes de executar este script."
  )
}

arquivos_csv <- list.files(
  DIR_CSV_TRATADOS,
  pattern = "-tratado\\.csv$",
  full.names = TRUE
)

if (!length(arquivos_csv)) {
  stop("Nenhum CSV tratado foi encontrado em: ", DIR_CSV_TRATADOS)
}

dir.create(DIR_PARQUET, recursive = TRUE, showWarnings = FALSE)

for (arquivo_csv in arquivos_csv) {
  nome_parquet <- sub("\\.csv$", ".parquet", basename(arquivo_csv))
  caminho_parquet <- file.path(DIR_PARQUET, nome_parquet)

  # code_muni fica como texto para preservar exatamente os sete digitos do IBGE.
  dados <- readr::read_csv2(
    arquivo_csv,
    col_types = readr::cols(code_muni = readr::col_character()),
    show_col_types = FALSE
  )

  arrow::write_parquet(dados, caminho_parquet, compression = "snappy")

  tamanho_csv_mb <- round(file.info(arquivo_csv)$size / 1024^2, 2)
  tamanho_parquet_mb <- round(file.info(caminho_parquet)$size / 1024^2, 2)
  message(
    "Convertido: ", basename(arquivo_csv),
    " -> ", caminho_parquet,
    " (", tamanho_csv_mb, " MB -> ", tamanho_parquet_mb, " MB)"
  )
}

message(
  "\nConversao concluida. Os arquivos estao em ", DIR_PARQUET,
  ".\nEm seguida, execute 04_publicar_combustiveis_parquet.R",
  " para envia-los como assets da Release no GitHub usando piggyback."
)
