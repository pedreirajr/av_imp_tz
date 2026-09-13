
pacotes <- c("readr", "dplyr", "tidyr", "stringr", "geobr", "purrr")
faltando <- pacotes[!vapply(pacotes, requireNamespace, logical(1), quietly = TRUE)]
if (length(faltando)) install.packages(faltando, repos = "https://cloud.r-project.org")
invisible(lapply(pacotes, library, character.only = TRUE))

DIR_DATA_RAW <- "data-raw"
DIR_DATA_TRATADOS <- "data"
dir.create(DIR_DATA_TRATADOS, recursive = TRUE, showWarnings = FALSE)

# ---- 1. Referência oficial (via geobr, não via outro script do projeto) ------
referencia_muni <- geobr::lookup_muni(year = 2022, name_muni = "all")
# print(names(referencia_muni))  # confira os nomes reais antes de seguir

referencia_muni <- referencia_muni |>
  dplyr::select(name_region, abbrev_state, code_muni, name_muni)  # complete com os nomes que aparecerem no print

# ---- 2. Configuração por arquivo (equivalente ao seu dicionário Python) -----
configuracoes <- list(
  "vendas-anuais-de-gasolina-c-por-municipio-raw.csv" = "padrao",
  "vendas-anuais-de-etanol-hidratado-por-municipio-raw.csv" = "padrao",
  "vendas-anuais-de-oleo-diesel-por-municipio-raw.csv" = "padrao",
  "vendas-anuais-de-glp-por-municipio-raw.csv" = "glp"
)

# ---- 3. Função de tratamento -------------------------------------------------
tratar_arquivo <- function(tipo, nome_arquivo) {
  print(paste("tipo:", tipo, "| arquivo:", nome_arquivo))
  caminho_entrada <- file.path(DIR_DATA_RAW, nome_arquivo)

  # read_csv2: já assume ";" e decimal "," — resolve de cara o problema
  # de formatação numérica que você teve no pandas
  df <- readr::read_csv2(caminho_entrada)

  if (tipo == "padrao") {
    df <- df |>
      dplyr::rename(
        date = ANO,
        code_muni = `CÓDIGO IBGE`,
        vendas_litros = VENDAS,
        name_region_anp = `GRANDE REGIÃO`,
        abbrev_state_anp = UF,
        name_muni_anp = MUNICÍPIO
      ) |>
      dplyr::select(
        date, code_muni, vendas_litros,
        name_region_anp, abbrev_state_anp, name_muni_anp
      )
  } else {
    df <- df |>
      dplyr::rename(
        date = ANO,
        code_muni = `CÓDIGO IBGE`,
        vendas_vasilhames_p13_kg = P13,
        vendas_vasilhames_outros_kg = OUTROS,
        name_region_anp = `GRANDE REGIÃO`,
        abbrev_state_anp = UF,
        name_muni_anp = MUNICÍPIO
      ) |>
      dplyr::select(
        date, code_muni,
        vendas_vasilhames_p13_kg, vendas_vasilhames_outros_kg,
        name_region_anp, abbrev_state_anp, name_muni_anp
      ) |>
      tidyr::pivot_longer(
        cols = c(vendas_vasilhames_p13_kg, vendas_vasilhames_outros_kg),
        names_to = "tipo_vasilhame",
        values_to = "valor_kg"
      )
  }

  # junta com a referência oficial, trazendo name_muni/UF/região corretos
  df <- df |>
    dplyr::left_join(referencia_muni, by = "code_muni") |>
    dplyr::mutate(
      fonte_geografia = dplyr::if_else(
        is.na(name_muni),
        "ANP: codigo nao encontrado no geobr",
        "geobr"
      ),
      name_region = dplyr::coalesce(name_region, name_region_anp),
      abbrev_state = dplyr::coalesce(abbrev_state, abbrev_state_anp),
      name_muni = dplyr::coalesce(name_muni, name_muni_anp)
    )

  caminho_saida <- file.path(
    DIR_DATA_TRATADOS,
    stringr::str_replace(nome_arquivo, "-raw", "-tratado")
  )

  readr::write_csv2(df, caminho_saida)
  message("Tratado e salvo: ", caminho_saida)
}
# 
# # ---- 4. Rodar para todos os arquivos -----------------------------------------
purrr::iwalk(configuracoes, tratar_arquivo)
