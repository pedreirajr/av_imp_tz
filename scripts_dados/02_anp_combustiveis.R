# =============================================================================
# 02_anp_combustiveis.R — Vendas municipais anuais de combustíveis (ANP)
#
# Produtos: Gasolina C, Etanol Hidratado, Óleo Diesel
# Série:    2010 em diante, todos os municípios do Brasil
# Fonte:    ANP — "Vendas de derivados de petróleo e biocombustíveis",
#           planilhas anuais POR MUNICÍPIO (gov.br/anp).
#
# Estrutura dos arquivos (validada): metadados nas linhas 1-7
#   (título, "UNIDADE DE MEDIDA: LITRO", "ANO: aaaa", cabeçalho), dados a partir
#   da linha 8 com 3 colunas: código IBGE (7 díg.), município, vendas (litros).
#   Arquivos antigos trazem linhas de subtotal por UF (código vazio) — descartadas
#   pelo filtro de código de 7 dígitos.
#
# Saídas:
#   data/anp_vendas_municipio_2010plus.csv  (formato longo)
#   data/painel_combustivel_anual.csv       (formato largo)
# =============================================================================

source("R/00_setup.R")

# Base e mapeamento produto -> (pasta, prefixo do arquivo)
ANP_BASE <- paste0(
  "https://www.gov.br/anp/pt-br/centrais-de-conteudo/dados-estatisticos/de/",
  "arquivos-vendas-de-derivados-de-petroleo-e-biocombustiveis"
)
ANP_PRODUTOS <- tibble::tribble(
  ~produto,            ~slug,
  "gasolina_c",        "gasolina-c",
  "etanol_hidratado",  "etanol-hidratado",
  "diesel",            "oleo-diesel"
)

# ---- Download (tenta .xlsx e, se faltar, .xls) -------------------------------
anp_baixar <- function(slug, ano) {
  for (ext in c("xlsx", "xls")) {
    url  <- sprintf("%s/%s/%s-municipio-%d.%s", ANP_BASE, slug, slug, ano, ext)
    dest <- file.path(DIR_ANP_RAW, sprintf("%s-%d.%s", slug, ano, ext))
    if (file.exists(dest) && file.size(dest) > 0) return(dest)
    ok <- tryCatch({
      r <- httr::GET(url, httr::write_disk(dest, overwrite = TRUE),
                     httr::timeout(120))
      httr::status_code(r) == 200 &&
        grepl("spreadsheet|excel|officedocument",
              httr::headers(r)[["content-type"]] %||% "", ignore.case = TRUE)
    }, error = function(e) FALSE)
    if (isTRUE(ok)) return(dest)
    if (file.exists(dest)) unlink(dest)
  }
  warning("Arquivo ANP indisponível: ", slug, " ", ano)
  NA_character_
}
`%||%` <- function(a, b) if (is.null(a)) b else a

# ---- Parser de uma planilha --------------------------------------------------
# Mantém só linhas cujo código IBGE tem 7 dígitos (descarta cabeçalho, subtotais
# de UF e total geral). Unidade de origem: LITRO.
anp_parse <- function(arquivo, produto, ano) {
  raw <- readxl::read_excel(arquivo, sheet = 1, col_names = FALSE,
                            .name_repair = "minimal")
  df  <- raw[, 1:3]
  names(df) <- c("code_muni", "name_muni_anp", "vendas_litros")
  df |>
    dplyr::mutate(code_muni = as.character(code_muni)) |>
    dplyr::filter(grepl("^[0-9]{7}$", code_muni)) |>
    dplyr::transmute(
      code_muni     = as.integer(code_muni),
      name_muni_anp = stringr::str_squish(name_muni_anp),
      ano           = ano,
      produto       = produto,
      vendas_litros = as.numeric(vendas_litros),
      vendas_m3     = as.numeric(vendas_litros) / 1000
    )
}

# ---- Coleta de todos os produtos x anos --------------------------------------
message("Baixando e processando vendas ANP (", min(ANOS_ANP), "-",
        max(ANOS_ANP), ") para ", nrow(ANP_PRODUTOS), " produtos...")

grade <- tidyr::expand_grid(ANP_PRODUTOS, ano = ANOS_ANP)

anp_long <- purrr::pmap_dfr(grade, function(produto, slug, ano) {
  arq <- anp_baixar(slug, ano)
  if (is.na(arq)) return(NULL)
  out <- tryCatch(anp_parse(arq, produto, ano),
                  error = function(e) { warning("Erro lendo ", arq, ": ",
                                                conditionMessage(e)); NULL })
  if (!is.null(out)) message("  ok: ", slug, " ", ano, " (", nrow(out), " mun.)")
  out
})

# ---- Padroniza nome/UF: usa lookup do geobr (01) se existir; senão deriva a UF
#      do prefixo do código IBGE (sempre disponível, ver 00_setup.R) -----------
lookup_path <- file.path(DIR_DATA, "municipios_lookup.csv")
if (file.exists(lookup_path)) {
  lookup <- readr::read_csv(lookup_path, show_col_types = FALSE)
  anp_long <- anp_long |>
    dplyr::left_join(lookup, by = "code_muni") |>
    dplyr::mutate(
      name_muni    = dplyr::coalesce(name_muni, name_muni_anp),
      abbrev_state = dplyr::coalesce(abbrev_state, uf_do_code_muni(code_muni))
    )
} else {
  message("Lookup do geobr ausente; UF derivada do código IBGE.")
  anp_long <- anp_long |>
    dplyr::mutate(name_muni    = name_muni_anp,
                  abbrev_state = uf_do_code_muni(code_muni))
}
anp_long <- dplyr::select(anp_long, code_muni, name_muni, abbrev_state, ano,
                          produto, vendas_litros, vendas_m3)

anp_long <- dplyr::arrange(anp_long, code_muni, produto, ano)

# ---- Saídas ------------------------------------------------------------------
readr::write_csv(anp_long,
                 file.path(DIR_DATA, "anp_vendas_municipio_2010plus.csv"))

painel_largo <- anp_long |>
  dplyr::select(code_muni, name_muni, abbrev_state, ano, produto, vendas_m3) |>
  tidyr::pivot_wider(names_from = produto, values_from = vendas_m3,
                     names_glue = "{produto}_m3")

readr::write_csv(painel_largo,
                 file.path(DIR_DATA, "painel_combustivel_anual.csv"))

message("OK ANP: ", nrow(anp_long), " linhas (longo); ",
        nrow(painel_largo), " linhas (painel largo). ",
        dplyr::n_distinct(anp_long$ano), " anos, ",
        dplyr::n_distinct(anp_long$produto), " produtos.")
