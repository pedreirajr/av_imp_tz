# =============================================================================
# 01_municipios_geobr.R — Polígonos e tabela de referência dos municípios (IBGE)
#
# Saídas:
#   data/municipios_br.gpkg     — geometrias (sf) de todos os municípios do BR
#                                 (necessário para o recorte zonal do TROPOMI, 03)
#   data/municipios_lookup.csv  — chave code_muni <-> nome/UF (sem geometria)
#
# A tabela de lookup é usada para padronizar os códigos IBGE do recorte zonal
# do TROPOMI (03).
#
# Estratégia de obtenção (em cascata, para ser robusta a falhas do geobr):
#   1) geobr::read_municipality()  — fonte preferida;
#   2) malha municipal oficial do IBGE (shapefile único) — usada quando o
#      download do geobr falha (erro recorrente "file corrupted during download");
#   3) somente o LOOKUP via API de localidades do IBGE — quando não há geometrias.
# =============================================================================

source("scripts_dados/00_setup.R")
.load_geo()

# ---- Lookup via API do IBGE (sempre disponível; não depende do geobr) --------
lookup_via_ibge <- function() {
  if (!requireNamespace("jsonlite", quietly = TRUE))
    install.packages("jsonlite", repos = "https://cloud.r-project.org")
  url <- "https://servicodados.ibge.gov.br/api/v1/localidades/municipios"
  j <- jsonlite::fromJSON(url, flatten = TRUE)
  tibble::tibble(
    code_muni    = as.integer(j$id),
    name_muni    = j$nome,
    abbrev_state = j$`microrregiao.mesorregiao.UF.sigla`,
    code_state   = as.integer(j$`microrregiao.mesorregiao.UF.id`)
  ) |>
    # Backstop: deriva UF/código do estado pelo prefixo do código IBGE quando a
    # hierarquia de microrregião vier vazia (ex.: municípios recém-criados).
    dplyr::mutate(
      abbrev_state = dplyr::coalesce(abbrev_state, uf_do_code_muni(code_muni)),
      code_state   = dplyr::coalesce(code_state,
                       as.integer(substr(sprintf("%07d", code_muni), 1, 2)))
    ) |>
    dplyr::distinct(code_muni, .keep_all = TRUE) |>
    dplyr::arrange(code_muni)
}

# ---- Geometrias via malha oficial do IBGE (fallback ao geobr) ----------------
# Baixa o shapefile único BR_Municipios e padroniza as colunas. Não depende do
# host de dados do geobr. Atributos do shp: CD_MUN (código 7 díg.), NM_MUN, SIGLA_UF.
geom_via_ibge_shp <- function(ano = 2022) {
  options(timeout = max(getOption("timeout"), 1800))  # arquivo ~200 MB
  dir_shp <- file.path(DIR_DATA_RAW, "ibge_malha")
  dir.create(dir_shp, recursive = TRUE, showWarnings = FALSE)
  url <- sprintf(paste0("https://geoftp.ibge.gov.br/organizacao_do_territorio/",
                        "malhas_territoriais/malhas_municipais/municipio_%d/",
                        "Brasil/BR/BR_Municipios_%d.zip"), ano, ano)
  zip <- file.path(dir_shp, basename(url))
  if (!file.exists(zip) || file.size(zip) < 1e6) baixar_arquivo(url, zip)
  utils::unzip(zip, exdir = dir_shp)
  shp <- list.files(dir_shp, pattern = "\\.shp$", full.names = TRUE,
                    recursive = TRUE)[1]
  m <- sf::st_read(shp, quiet = TRUE)
  m |>
    dplyr::transmute(
      code_muni    = as.integer(CD_MUN),
      name_muni    = NM_MUN,
      abbrev_state = if ("SIGLA_UF" %in% names(m)) SIGLA_UF else uf_do_code_muni(CD_MUN),
      code_state   = as.integer(substr(sprintf("%07d", as.integer(CD_MUN)), 1, 2))
    ) |>
    sf::st_transform(4674)
}

# ---- Cascata: geobr -> shapefile IBGE -> (lookup-only) -----------------------
message("Baixando malha municipal via geobr (geometrias)...")
municipios <- tryCatch(
  geobr::read_municipality(code_muni = "all", year = 2022,
                           simplified = FALSE, showProgress = FALSE),
  error = function(e) { message("geobr indisponível (", conditionMessage(e),
                                "). Tentando malha oficial do IBGE..."); NULL }
)
if (is.null(municipios)) {
  municipios <- tryCatch(geom_via_ibge_shp(2022),
    error = function(e) { message("Malha IBGE indisponível (",
                                  conditionMessage(e), ")."); NULL })
}

if (!is.null(municipios)) {
  sf::st_write(municipios, file.path(DIR_DATA, "municipios_br.gpkg"),
               delete_dsn = TRUE, quiet = TRUE)
  lookup <- municipios |>
    sf::st_drop_geometry() |>
    dplyr::transmute(code_muni = as.integer(code_muni), name_muni,
                     code_state = as.integer(code_state), abbrev_state) |>
    dplyr::arrange(code_muni)
  message("Geometrias salvas em data/municipios_br.gpkg")
} else {
  message("Gerando apenas o lookup via API do IBGE...")
  lookup <- lookup_via_ibge()
}

readr::write_csv(lookup, file.path(DIR_DATA, "municipios_lookup.csv"))
message("OK: ", nrow(lookup), " municípios em ",
        file.path(DIR_DATA, "municipios_lookup.csv"),
        if (is.null(municipios)) " (sem geometrias — rode localmente p/ o gpkg)."
        else ".")
