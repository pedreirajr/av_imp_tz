# =============================================================================
# 03b_consolidar_gee.R — Consolida os CSVs exportados pelo GEE Code Editor
#
# Use este script quando a extração da poluição for feita pelo Code Editor
# (gee/tropomi_export.js) em vez do rgee. Passos:
#   1) rode gee/tropomi_export.js no Code Editor e rode as tarefas (Tasks);
#   2) baixe os CSVs da pasta do Drive "tropomi_tarifazero" para data-raw/gee/;
#   3) rode este script.
#
# Entrada:  data-raw/gee/tropomi_*.csv  (colunas: code_muni, ano, mes, poluente, mean)
# Saídas:   data/poluicao_tropomi_mensal.csv  e  data/poluicao_tropomi_anual.csv
# =============================================================================

source("scripts_dados/00_setup.R")

csvs <- list.files(DIR_GEE_RAW, pattern = "^tropomi_.*\\.csv$", full.names = TRUE)
if (length(csvs) == 0)
  stop("Nenhum CSV em ", DIR_GEE_RAW,
       ". Baixe os arquivos exportados do Drive para essa pasta primeiro.")

message("Consolidando ", length(csvs), " arquivos de ", DIR_GEE_RAW, "...")

mensal <- purrr::map_dfr(csvs, readr::read_csv, show_col_types = FALSE) |>
  dplyr::transmute(
    code_muni = as.integer(code_muni),
    ano       = as.integer(ano),
    mes       = as.integer(mes),
    poluente  = poluente,            # "no2" (indicador de NOx) ou "co"
    valor     = as.numeric(mean)     # mol/m²
  ) |>
  dplyr::filter(!is.na(code_muni)) |>
  dplyr::arrange(code_muni, poluente, ano, mes)

readr::write_csv(mensal, file.path(DIR_DATA, "poluicao_tropomi_mensal.csv"))

anual <- mensal |>
  dplyr::group_by(code_muni, ano, poluente) |>
  dplyr::summarise(valor = mean(valor, na.rm = TRUE), n_meses = dplyr::n(),
                   .groups = "drop")

readr::write_csv(anual, file.path(DIR_DATA, "poluicao_tropomi_anual.csv"))

message("OK: ", nrow(mensal), " linhas mensais; ", nrow(anual), " anuais. ",
        "Poluentes: ", paste(unique(mensal$poluente), collapse = ", "),
        " | anos: ", paste(range(mensal$ano), collapse = "-"))
