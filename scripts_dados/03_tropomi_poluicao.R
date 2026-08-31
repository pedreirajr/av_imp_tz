# =============================================================================
# 03_tropomi_poluicao.R — Poluição troposférica (CO e NOx/NO2) via Sentinel-5P
#
#  >>> ESTE SCRIPT RODA NA SUA MÁQUINA, NÃO NO AMBIENTE REMOTO <<<
#  Requer uma conta no Google Earth Engine. Antes de rodar a 1ª vez:
#     rgee::ee_install()        # cria o ambiente Python (uma vez)
#     rgee::ee_Authenticate()   # autentica sua conta Google/EE (OAuth no browser)
#  Em seguida ajuste EE_PROJECT abaixo para o id do seu projeto do Earth Engine.
#
# Fonte (Sentinel-5P TROPOMI, nível L3 no Earth Engine):
#   NO2: COPERNICUS/S5P/OFFL/L3_NO2  banda tropospheric_NO2_column_number_density
#   CO : COPERNICUS/S5P/OFFL/L3_CO   banda CO_column_number_density
#   Unidade de ambos: mol/m². Disponível a partir de 2018-07.
#
# Nota metodológica:
#   - O produto satelital é NO2 troposférico, usado como PROXY de NOx.
#   - O pré-período é curto (TROPOMI inicia 2018-07; tratamentos em 2022-2023),
#     especialmente para Paranaguá (mar/2022). A resolução MENSAL maximiza os
#     pontos pré-intervenção.
#
# Saídas:
#   data/poluicao_tropomi_mensal.csv  (code_muni, ano, mes, poluente, valor)
#   data/poluicao_tropomi_anual.csv   (agregação anual, média dos meses)
# =============================================================================

source("scripts_dados/00_setup.R")
.load_geo()

if (!requireNamespace("rgee", quietly = TRUE)) {
  install.packages("rgee", repos = "https://cloud.r-project.org")
}
library(rgee)

# ---- Configuração do usuário -------------------------------------------------
EE_PROJECT <- Sys.getenv("EE_PROJECT", unset = "SEU-PROJETO-EE")  # <-- ajuste
DATA_FIM   <- Sys.Date()        # coleta até hoje
MESES_SEQ  <- seq(TROPOMI_INICIO, DATA_FIM, by = "month")

# MODO DE TESTE (opcional): defina os anos a coletar para um teste rápido antes
# de disparar a série inteira. Ex.: Sys.setenv(EE_ANOS_TESTE = "2019") roda só
# 2019 (12 meses x 2 poluentes) e valida a exportação p/ o Drive em poucos
# minutos. Deixe vazio para coletar a série completa.
ANOS_TESTE <- {
  v <- Sys.getenv("EE_ANOS_TESTE", unset = "")
  if (nzchar(v)) as.integer(strsplit(v, "[,;[:space:]]+")[[1]]) else NULL
}

# ---- Inicialização do Earth Engine -------------------------------------------
# Em algumas combinações de versões, o ee_Initialize() do rgee dá um erro falso
# de "credential has expired" mesmo com a credencial válida (o ee$Initialize do
# Python funciona). Por isso tentamos o rgee e, se falhar, inicializamos via
# Python diretamente, mantendo o rgee carregado para os helpers.
# Pré-requisito: rode antes  googledrive::drive_auth()  (autentica o Drive).
ee <- reticulate::import("ee")
ok_rgee <- tryCatch({
  ee_Initialize(project = EE_PROJECT, drive = TRUE); TRUE
}, error = function(e) {
  message("ee_Initialize (rgee) falhou: ", conditionMessage(e),
          "\n  -> inicializando via Python diretamente..."); FALSE
})
if (!ok_rgee) {
  ee$Initialize(project = EE_PROJECT)
  if (!requireNamespace("googledrive", quietly = TRUE))
    install.packages("googledrive")
  if (!googledrive::drive_has_token())
    googledrive::drive_auth()   # necessário p/ baixar os CSVs exportados
}
message("Earth Engine inicializado. Teste: ", ee$String("ok")$getInfo())

# ---- Municípios como FeatureCollection ---------------------------------------
# Duas formas de levar os municípios ao Earth Engine:
#  (a) ASSET (recomendado p/ o Brasil inteiro): defina EE_MUNICIPIOS_ASSET com o
#      ID de um asset de municípios já enviado ao EE — evita o limite de tamanho
#      do sf_as_ee com muitas geometrias;
#  (b) sf_as_ee: converte as geometrias locais na hora (requer o pacote
#      geojsonio; pode estourar o limite de payload do EE com ~5.570 municípios).
ASSET_MUNI   <- Sys.getenv("EE_MUNICIPIOS_ASSET", unset = "")
# Nome da coluna do código do município no asset (ex.: "CD_MUN" no shapefile do
# IBGE, "code_muni" no geobr). É normalizado para "code_muni" abaixo.
MUNI_ID_PROP <- Sys.getenv("EE_MUNI_ID_PROP", unset = "code_muni")

if (nzchar(ASSET_MUNI)) {
  message("Usando municípios do asset: ", ASSET_MUNI,
          " (coluna do código: ", MUNI_ID_PROP, ")")
  municipios_ee <- ee$FeatureCollection(ASSET_MUNI)
  # Normaliza o nome da coluna do código para "code_muni".
  if (MUNI_ID_PROP != "code_muni")
    municipios_ee <- municipios_ee$map(
      function(f) f$set("code_muni", f$get(MUNI_ID_PROP)))
} else {
  if (!requireNamespace("geojsonio", quietly = TRUE)) install.packages("geojsonio")
  municipios <- sf::st_read(file.path(DIR_DATA, "municipios_br.gpkg"), quiet = TRUE)
  municipios <- sf::st_transform(municipios, 4326)
  municipios <- sf::st_simplify(municipios, dTolerance = 0.001,
                                preserveTopology = TRUE)
  municipios <- municipios[, c("code_muni")]
  message("Convertendo ", nrow(municipios), " municípios via sf_as_ee()...")
  municipios_ee <- rgee::sf_as_ee(municipios)
}

# ---- Coleções TROPOMI --------------------------------------------------------
S5P <- list(
  no2 = list(col = "COPERNICUS/S5P/OFFL/L3_NO2",
             band = "tropospheric_NO2_column_number_density"),
  co  = list(col = "COPERNICUS/S5P/OFFL/L3_CO",
             band = "CO_column_number_density")
)

# Escala (m) das grades L3: NO2 ~1113 m; CO ~1113 m. Usada no reduceRegions.
ESCALA <- 1113.2

# ---- Extrai a média zonal mensal de uma coleção, por ano (export ao Drive) ---
# Exporta um CSV por ano p/ evitar timeout do EE; depois baixa e empilha.
extrair_poluente <- function(nome, info, ano) {
  meses_ano <- MESES_SEQ[format(MESES_SEQ, "%Y") == as.character(ano)]
  if (length(meses_ano) == 0) return(NULL)

  # Resumível: se o CSV deste poluente/ano já foi baixado, pula.
  dest <- file.path(DIR_GEE_RAW, sprintf("tropomi_%s_%d.csv", nome, ano))
  if (file.exists(dest) && file.size(dest) > 0) {
    message("  já baixado, pulando: ", basename(dest)); return(dest)
  }

  ic <- ee$ImageCollection(info$col)$select(info$band)

  # Para cada mês: média do mês e reduceRegions sobre os municípios.
  por_mes <- lapply(meses_ano, function(m1) {
    m2 <- seq(m1, by = "month", length.out = 2)[2]
    img <- ic$filterDate(rdate_to_eedate(m1), rdate_to_eedate(m2))$mean()
    fc  <- img$reduceRegions(
      collection = municipios_ee,
      reducer    = ee$Reducer$mean(),
      scale      = ESCALA
    )
    mes_num <- as.integer(format(m1, "%m"))
    fc$map(function(f) f$set(list(ano = ano, mes = mes_num,
                                  poluente = nome)))
  })

  fc_ano <- ee$FeatureCollection(por_mes)$flatten()

  tarefa <- ee_table_to_drive(
    collection  = fc_ano,
    description = sprintf("tropomi_%s_%d", nome, ano),
    fileFormat  = "CSV",
    selectors   = c("code_muni", "ano", "mes", "poluente", "mean")
  )
  tarefa$start()
  ee_monitoring(tarefa, max_attempts = 1000)
  ee_drive_to_local(tarefa, dsn = dest)
  dest
}

# ---- Loop por poluente e ano -------------------------------------------------
anos_tropomi <- sort(unique(as.integer(format(MESES_SEQ, "%Y"))))
if (!is.null(ANOS_TESTE)) {
  anos_tropomi <- intersect(anos_tropomi, ANOS_TESTE)
  message(">> MODO DE TESTE: coletando apenas o(s) ano(s) ",
          paste(anos_tropomi, collapse = ", "))
}
arquivos <- character(0)
for (nm in names(S5P)) {
  for (a in anos_tropomi) {
    message("TROPOMI ", nm, " ", a, " ...")
    f <- tryCatch(extrair_poluente(nm, S5P[[nm]], a),
                  error = function(e) { warning(conditionMessage(e)); NULL })
    if (!is.null(f)) arquivos <- c(arquivos, f)
  }
}

# ---- Consolida ---------------------------------------------------------------
csvs_gee <- list.files(DIR_GEE_RAW, pattern = "^tropomi_.*\\.csv$",
                       full.names = TRUE)
if (length(csvs_gee) == 0)
  stop("Nenhum CSV foi exportado/baixado do Earth Engine. Verifique os avisos ",
       "acima (ex.: falha no sf_as_ee/geojsonio ou na exportação para o Drive).")

mensal <- purrr::map_dfr(
  csvs_gee,
  readr::read_csv, show_col_types = FALSE
) |>
  dplyr::transmute(
    code_muni = as.integer(code_muni),
    ano       = as.integer(ano),
    mes       = as.integer(mes),
    poluente  = poluente,             # "no2" (proxy NOx) ou "co"
    valor     = as.numeric(mean)      # mol/m²
  ) |>
  dplyr::arrange(code_muni, poluente, ano, mes)

readr::write_csv(mensal, file.path(DIR_DATA, "poluicao_tropomi_mensal.csv"))

anual <- mensal |>
  dplyr::group_by(code_muni, ano, poluente) |>
  dplyr::summarise(valor = mean(valor, na.rm = TRUE), n_meses = dplyr::n(),
                   .groups = "drop")

readr::write_csv(anual, file.path(DIR_DATA, "poluicao_tropomi_anual.csv"))

message("OK TROPOMI: ", nrow(mensal), " linhas mensais; ",
        nrow(anual), " linhas anuais.")
