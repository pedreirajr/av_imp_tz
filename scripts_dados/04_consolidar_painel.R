# =============================================================================
# 04_consolidar_painel.R — Painéis finais para o controle sintético
#
# Junta os desfechos coletados (combustível anual + poluição mensal/anual) e
# marca as cidades tratadas. Não reexecuta downloads; só lê as saídas de 02 e 03.
#
# Saídas:
#   data/painel_combustivel_anual.csv   (já gerado em 02; aqui acrescenta flags)
#   data/painel_poluicao_mensal.csv
#   data/painel_poluicao_anual.csv
# =============================================================================

source("scripts_dados/00_setup.R")

ler_se_existir <- function(path) {
  if (file.exists(path)) readr::read_csv(path, show_col_types = FALSE)
  else { warning("Arquivo ausente: ", path, " (rode o script que o gera)."); NULL }
}

# Flags das cidades do estudo (tratadas + substitutas)
flags_cidades <- CIDADES_ALVO |>
  dplyr::transmute(code_muni, papel, data_tratamento,
                   tratada = papel == "tratada")

# ---- Combustível (anual) -----------------------------------------------------
comb <- ler_se_existir(file.path(DIR_DATA, "painel_combustivel_anual.csv"))
if (!is.null(comb)) {
  comb |>
    dplyr::left_join(flags_cidades, by = "code_muni") |>
    dplyr::mutate(tratada = dplyr::coalesce(tratada, FALSE)) |>
    readr::write_csv(file.path(DIR_DATA, "painel_combustivel_anual.csv"))
}

# ---- Poluição (mensal e anual) ----------------------------------------------
pol_m <- ler_se_existir(file.path(DIR_DATA, "poluicao_tropomi_mensal.csv"))
if (!is.null(pol_m)) {
  pol_m |>
    tidyr::pivot_wider(names_from = poluente, values_from = valor,
                       names_glue = "{poluente}_col_mol_m2") |>
    dplyr::left_join(flags_cidades, by = "code_muni") |>
    dplyr::mutate(tratada = dplyr::coalesce(tratada, FALSE)) |>
    readr::write_csv(file.path(DIR_DATA, "painel_poluicao_mensal.csv"))
}

pol_a <- ler_se_existir(file.path(DIR_DATA, "poluicao_tropomi_anual.csv"))
if (!is.null(pol_a)) {
  pol_a |>
    tidyr::pivot_wider(names_from = poluente,
                       values_from = c(valor, n_meses),
                       names_glue = "{poluente}_{.value}") |>
    dplyr::left_join(flags_cidades, by = "code_muni") |>
    dplyr::mutate(tratada = dplyr::coalesce(tratada, FALSE)) |>
    readr::write_csv(file.path(DIR_DATA, "painel_poluicao_anual.csv"))
}

message("Consolidação concluída (arquivos disponíveis foram atualizados).")
