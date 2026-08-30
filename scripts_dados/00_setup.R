# =============================================================================
# 00_setup.R — Configuração, pacotes e parâmetros do projeto
# Projeto Tarifa Zero / ANPET — coleta de desfechos (parte do Thomas)
#
# Carregue este script no início dos demais:  source("scripts_dados/00_setup.R")
# =============================================================================

# ---- Pacotes -----------------------------------------------------------------
# Instala o que faltar e carrega. `rgee` só é necessário para o script 03.
.pkgs <- c(
  "tibble", "dplyr", "tidyr", "readr", "readxl", "stringr", "purrr", "httr"
)
# Pacotes espaciais / Earth Engine (usados em 01 e 03)
.pkgs_geo <- c("geobr", "sf")

.install_if_missing <- function(pkgs) {
  faltando <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(faltando)) {
    message("Instalando pacotes: ", paste(faltando, collapse = ", "))
    install.packages(faltando, repos = "https://cloud.r-project.org")
  }
}

.install_if_missing(.pkgs)
invisible(lapply(.pkgs, library, character.only = TRUE))

# Carrega pacotes geográficos se já instalados (não obriga, p/ rodar só a ANP)
.load_geo <- function() {
  .install_if_missing(.pkgs_geo)
  invisible(lapply(.pkgs_geo, library, character.only = TRUE))
}

# ---- Caminhos ----------------------------------------------------------------
DIR_DATA     <- "data"
DIR_DATA_RAW <- "data-raw"
DIR_ANP_RAW  <- file.path(DIR_DATA_RAW, "anp")
DIR_GEE_RAW  <- file.path(DIR_DATA_RAW, "gee")

for (d in c(DIR_DATA, DIR_DATA_RAW, DIR_ANP_RAW, DIR_GEE_RAW)) {
  if (!dir.exists(d)) dir.create(d, recursive = TRUE)
}

# ---- Parâmetros do estudo ----------------------------------------------------
# Série histórica da ANP (consumo de combustíveis)
ANOS_ANP <- 2010:2024

# UFs das cidades tratadas (3) + substitutas (2) — usado como fallback de recorte
UFS_ALVO <- c("GO", "SP", "PR", "SC", "MT")

# TROPOMI (Sentinel-5P) disponível a partir de jul/2018
TROPOMI_INICIO <- as.Date("2018-07-01")

# Produtos ANP de interesse (rótulos podem variar entre arquivos; ver 02)
PRODUTOS_ANP <- c("GASOLINA C", "ETANOL HIDRATADO", "OLEO DIESEL")

# ---- Cidades do estudo (código IBGE 7 dígitos + data de implementação) -------
# 3 tratadas + 2 substitutas. Datas conforme noticiário oficial das prefeituras.
CIDADES_ALVO <- tibble::tribble(
  ~code_muni, ~name_muni,             ~abbrev_state, ~data_tratamento, ~papel,
  5212501L,   "Luziânia",             "GO",          "2023-11-27",     "tratada",
  3522307L,   "Itapetininga",         "SP",          "2023-12-01",     "tratada",
  4118204L,   "Paranaguá",            "PR",          "2022-03-01",     "tratada",
  4202008L,   "Balneário Camboriú",   "SC",          NA_character_,    "substituta",
  5107925L,   "Sorriso",              "MT",          NA_character_,    "substituta"
) |>
  dplyr::mutate(data_tratamento = as.Date(data_tratamento))

# ---- UF a partir do código IBGE (prefixo de 2 dígitos) -----------------------
# Permite anexar a UF sem depender do geobr (cuja instalação é pesada).
UF_POR_CODIGO <- c(
  "11" = "RO", "12" = "AC", "13" = "AM", "14" = "RR", "15" = "PA", "16" = "AP",
  "17" = "TO", "21" = "MA", "22" = "PI", "23" = "CE", "24" = "RN", "25" = "PB",
  "26" = "PE", "27" = "AL", "28" = "SE", "29" = "BA", "31" = "MG", "32" = "ES",
  "33" = "RJ", "35" = "SP", "41" = "PR", "42" = "SC", "43" = "RS", "50" = "MS",
  "51" = "MT", "52" = "GO", "53" = "DF"
)
uf_do_code_muni <- function(code_muni) {
  unname(UF_POR_CODIGO[substr(sprintf("%07d", as.integer(code_muni)), 1, 2)])
}

# ---- Helper de download robusto ---------------------------------------------
# Baixa `url` para `destfile` com tentativas e backoff exponencial.
baixar_arquivo <- function(url, destfile, tentativas = 4, modo = "wb") {
  for (i in seq_len(tentativas)) {
    ok <- tryCatch({
      resp <- httr::GET(url, httr::write_disk(destfile, overwrite = TRUE),
                        httr::timeout(120))
      httr::status_code(resp) < 400 && file.exists(destfile) &&
        file.size(destfile) > 0
    }, error = function(e) FALSE)
    if (isTRUE(ok)) return(invisible(destfile))
    Sys.sleep(2^i)  # 2s, 4s, 8s, 16s
  }
  stop("Falha ao baixar após ", tentativas, " tentativas: ", url)
}

message("Setup carregado. Diretórios prontos em '", DIR_DATA, "' e '",
        DIR_DATA_RAW, "'.")
