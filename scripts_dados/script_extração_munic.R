

pacotes <- c("readxl", "dplyr", "purrr", "stringr", "readr", "tibble")
faltando <- pacotes[!pacotes %in% rownames(installed.packages())]
if (length(faltando) > 0) install.packages(faltando)
invisible(lapply(pacotes, library, character.only = TRUE))

options(timeout = 600)  # arquivos de 8 a 24 MB; o FTP do IBGE às vezes é lento

dir_raw  <- file.path("data", "raw", "munic")
dir_proc <- file.path("data", "processed")
dir.create(dir_raw,  recursive = TRUE, showWarnings = FALSE)
dir.create(dir_proc, recursive = TRUE, showWarnings = FALSE)

# -----------------------------------------------------------------------------
# 1. Fontes (FTP oficial do IBGE)
# -----------------------------------------------------------------------------
fontes <- tibble::tribble(
  ~ano, ~url,
  2017, "https://ftp.ibge.gov.br/Perfil_Municipios/2017/Base_de_Dados/Base_MUNIC_2017_xls.zip",
  2020, "https://ftp.ibge.gov.br/Perfil_Municipios/2020/Base_de_Dados/Base_MUNIC_2020.xlsx",
  2024, "https://ftp.ibge.gov.br/Perfil_Municipios/2024/Base_de_Dados/Base_MUNIC_2024_20251107.xlsx"
)

# -----------------------------------------------------------------------------
# 2. Download (pula se o arquivo já existe) e descompactação
# -----------------------------------------------------------------------------
baixar_base <- function(ano, url) {
  destino <- file.path(dir_raw, basename(url))
  if (!file.exists(destino)) {
    message("Baixando MUNIC ", ano, " ...")
    download.file(url, destino, mode = "wb")
  }
  if (str_detect(destino, "\\.zip$")) {
    pasta <- file.path(dir_raw, paste0("munic_", ano))
    unzip(destino, exdir = pasta)
    destino <- list.files(pasta, pattern = "\\.xlsx?$", full.names = TRUE,
                          recursive = TRUE)[1]
  }
  destino
}

fontes <- fontes |>
  mutate(arquivo = purrr::map2_chr(ano, url, baixar_base))

# -----------------------------------------------------------------------------
# 3. Inspeção: quais abas existem em cada edição
# -----------------------------------------------------------------------------
purrr::walk2(fontes$ano, fontes$arquivo, function(ano, arq) {
  cat("\n== MUNIC", ano, "— abas ==\n")
  print(readxl::excel_sheets(arq))
})

# -----------------------------------------------------------------------------
# 4. Funções auxiliares
# -----------------------------------------------------------------------------

# Acha a aba cujo nome contém "transp" (Transporte / Transporte e mobilidade)
achar_aba <- function(arq, padrao) {
  abas <- readxl::excel_sheets(arq)
  hit  <- abas[str_detect(str_to_lower(abas), padrao)]
  if (length(hit) == 0) return(NA_character_)
  hit[1]
}

# Acha a coluna com o código IBGE de 7 dígitos do município
achar_col_codigo <- function(df) {
  candidatas <- names(df)[purrr::map_lgl(df, function(x) {
    x <- as.character(x)
    mean(str_detect(x, "^\\d{7}$"), na.rm = TRUE) > 0.9
  })]
  if (length(candidatas) == 0) stop("Não achei coluna com código de 7 dígitos.")
  candidatas[1]
}

# -----------------------------------------------------------------------------
# 5. Extração do bloco de transporte
# -----------------------------------------------------------------------------
extrair_transporte <- function(ano, arq) {
  aba <- achar_aba(arq, "transp")
  if (is.na(aba)) {
    warning("MUNIC ", ano, ": nenhuma aba de transporte encontrada.")
    return(NULL)
  }
  df <- readxl::read_excel(arq, sheet = aba, col_types = "text")
  col_cod <- achar_col_codigo(df)
  
  df <- df |>
    rename(cod_ibge = all_of(col_cod)) |>
    mutate(ano_munic = ano, .before = 1)
  
  message(sprintf("MUNIC %d | aba '%s' | coluna de código '%s' | %d municípios | %d variáveis",
                  ano, aba, col_cod, nrow(df), ncol(df)))
  
  readr::write_csv(df, file.path(dir_proc, paste0("munic_transporte_", ano, ".csv")))
  df
}

transporte <- purrr::map2(fontes$ano, fontes$arquivo, extrair_transporte)
names(transporte) <- fontes$ano

# -----------------------------------------------------------------------------
# 6. Dicionário de variáveis (se a base trouxer uma aba de dicionário)
# -----------------------------------------------------------------------------
dicionarios <- purrr::map2(fontes$ano, fontes$arquivo, function(ano, arq) {
  aba <- achar_aba(arq, "dicion")
  if (is.na(aba)) {
    message("MUNIC ", ano, ": sem aba de dicionário — use o questionário em PDF.")
    return(NULL)
  }
  dic <- readxl::read_excel(arq, sheet = aba, col_types = "text")
  readr::write_csv(dic, file.path(dir_proc, paste0("munic_dicionario_", ano, ".csv")))
  dic
})
names(dicionarios) <- fontes$ano

# Busca uma palavra em qualquer coluna do dicionário de um ano.
# Ex.: procurar("2024", "gratuidade"); procurar("2020", "isenção")
procurar <- function(ano, termo) {
  dic <- dicionarios[[as.character(ano)]]
  if (is.null(dic)) return(invisible(NULL))
  dic |>
    filter(if_any(everything(),
                  ~ str_detect(str_to_lower(.x), str_to_lower(termo))))
}

# -----------------------------------------------------------------------------
# 7. Próximo passo (manual): identificar as colunas de interesse
# -----------------------------------------------------------------------------
# Rode, por exemplo:
#   procurar(2024, "gratuidade")         # quesito 18a (gratuidade total)
#   procurar(2024, "toda a popula")      # quesito 20.10 (isenção p/ toda a população)
#   procurar(2020, "isen")               # quesito 20 em 2020
#   procurar(2017, "intramunicipal")     # existência de ônibus intramunicipal
#
# Depois fixe os códigos encontrados aqui e gere a base enxuta:
#
# vars_2024 <- c("MTRA...", "MTRA...")   # preencher com os códigos reais
# transporte[["2024"]] |>
#   select(ano_munic, cod_ibge, any_of(vars_2024)) |>
#   readr::write_csv(file.path(dir_proc, "munic_tz_2024.csv"))