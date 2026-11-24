# Executar da raiz: Rscript scripts_dados/tests/test_bolsa_familia.R
if (.Platform$OS.type == "windows") {
  Sys.setlocale("LC_CTYPE", "Portuguese_Brazil.utf8")
}
library(testthat)

script <- if (file.exists("../bolsa_familia.R")) {
  "../bolsa_familia.R"
} else {
  "scripts_dados/bolsa_familia.R"
}
source(script, encoding = "UTF-8")

municipios_ref <- data.frame(
  code_muni = c(1200401L, 2605459L, 2927408L, 3550308L),
  name_muni = c("Rio Branco", "Fernando de Noronha", "Salvador", "São Paulo"),
  abbrev_state = c("AC", "PE", "BA", "SP"),
  code_state = c(12L, 26L, 29L, 35L),
  stringsAsFactors = FALSE
)

brutos_exemplo <- data.frame(
  ano = c(2021L, 2021L, 2021L, 2021L, 2021L),
  mes = c(10L, 11L, 11L, 11L, 11L),
  programa = c("bolsa_familia", "bolsa_familia", "auxilio_brasil", "auxilio_brasil", "auxilio_brasil"),
  sigla_uf_fonte = c("BA", "BA", "SP", "SP", NA_character_),
  id_municipio_fonte = c("2927408", "2927408", "3550308", "0000000", ""),
  qtd_familias = c(100, 90, 200, 5, 2),
  qtd_parcelas = c(105, 92, 200, 5, 2),
  valor_total = c(20000, 18000, 80000, 2000, 800),
  stringsAsFactors = FALSE
)

test_that("montar_query_bolsa_familia gera SQL com as 3 tabelas, filtro 2021-11 e métricas esperadas", {
  sql <- montar_query_bolsa_familia(ano_inicial = 2013L)
  expect_type(sql, "character")
  expect_length(sql, 1L)
  expect_match(sql, "basedosdados\\.br_cgu_beneficios_cidadao\\.bolsa_familia_pagamento")
  expect_match(sql, "basedosdados\\.br_cgu_beneficios_cidadao\\.auxilio_brasil")
  expect_match(sql, "basedosdados\\.br_cgu_beneficios_cidadao\\.novo_bolsa_familia")
  expect_match(sql, "'bolsa_familia' AS programa")
  expect_match(sql, "'auxilio_brasil' AS programa")
  expect_match(sql, "'novo_bolsa_familia' AS programa")
  expect_match(sql, "COUNT\\(DISTINCT nis_favorecido\\) AS qtd_familias")
  expect_match(sql, "COUNT\\(\\*\\) AS qtd_parcelas")
  expect_match(sql, "SUM\\(valor_parcela\\) AS valor_total")
  expect_match(sql, "NOT \\(programa = 'bolsa_familia' AND ano = 2021 AND mes = 11\\)")
  expect_match(sql, "GROUP BY ano, mes, programa, sigla_uf_fonte, id_municipio_fonte")
  expect_match(sql, ">= 2013")
  expect_error(montar_query_bolsa_familia(2002L), "ano_inicial")
})

test_that("validar_billing_id rejeita placeholder e valores vazios", {
  expect_identical(validar_billing_id("meu-projeto"), "meu-projeto")
  expect_error(validar_billing_id(""), "BILLING_ID.*\\.Renviron")
  expect_error(validar_billing_id("   "), "BILLING_ID.*\\.Renviron")
  expect_error(validar_billing_id("seuprojeto"), "BILLING_ID.*\\.Renviron")
  expect_error(validar_billing_id(NA_character_), "BILLING_ID.*\\.Renviron")
})

test_that("verificar_limite_bytes e baixar_resumo_bigquery aplicam trava de custo, RLS e cache opt-in", {
  limite <- 250 * 1024^3
  expect_true(verificar_limite_bytes(100 * 1024^3, max_bytes = limite))
  expect_true(verificar_limite_bytes(limite, max_bytes = limite))
  expect_error(
    verificar_limite_bytes(limite + 1, max_bytes = limite),
    "trava de custo.*250\\.00 GB"
  )
  expect_error(verificar_limite_bytes(NA_real_, max_bytes = limite), "inválida")
  expect_error(verificar_limite_bytes(-1, max_bytes = limite), "inválida")

  cache_tmp <- tempfile(fileext = ".rds")
  on.exit(unlink(cache_tmp), add = TRUE)

  chamadas_query <- 0L
  expect_error(
    baixar_resumo_bigquery(
      billing_id = "meu-projeto",
      max_bytes = 100 * 1024^3,
      usar_cache = FALSE,
      cache_path = cache_tmp,
      dry_run_fn = function(sql, billing) 150 * 1024^3,
      query_fn = function(sql, billing, max_bytes) {
        chamadas_query <<- chamadas_query + 1L
        data.frame()
      }
    ),
    "trava de custo"
  )
  expect_equal(chamadas_query, 0L)
  expect_false(file.exists(cache_tmp))

  # Quando BigQuery omite estimativa por Row-Level Security (numeric(0)), segue com max_bytes server-side.
  limite_repassado <- NA_real_
  res_rls <- baixar_resumo_bigquery(
    billing_id = "meu-projeto",
    max_bytes = 250 * 1024^3,
    usar_cache = FALSE,
    cache_path = NULL,
    dry_run_fn = function(sql, billing) numeric(0),
    query_fn = function(sql, billing, max_bytes) {
      limite_repassado <<- max_bytes
      brutos_exemplo
    }
  )
  expect_equal(limite_repassado, 250 * 1024^3)
  expect_equal(res_rls, brutos_exemplo)

  # Comportamento padrão (usar_cache = FALSE) sempre consulta e grava o cache local.
  res1 <- baixar_resumo_bigquery(
    billing_id = "meu-projeto",
    max_bytes = 250 * 1024^3,
    cache_path = cache_tmp,
    dry_run_fn = function(sql, billing) 90 * 1024^3,
    query_fn = function(sql, billing, max_bytes) {
      chamadas_query <<- chamadas_query + 1L
      brutos_exemplo
    }
  )
  expect_equal(chamadas_query, 1L)
  expect_equal(res1, brutos_exemplo)
  expect_true(file.exists(cache_tmp))

  # Mesmo com cache existente, o padrão (usar_cache = FALSE) volta a consultar o BigQuery.
  res_novo <- baixar_resumo_bigquery(
    billing_id = "meu-projeto",
    max_bytes = 250 * 1024^3,
    cache_path = cache_tmp,
    dry_run_fn = function(sql, billing) 90 * 1024^3,
    query_fn = function(sql, billing, max_bytes) {
      chamadas_query <<- chamadas_query + 1L
      brutos_exemplo
    }
  )
  expect_equal(chamadas_query, 2L)
  expect_equal(res_novo, brutos_exemplo)

  # Com usar_cache = TRUE explícito, reaproveita o cache sem chamar BigQuery.
  res2 <- baixar_resumo_bigquery(
    billing_id = "seuprojeto",
    max_bytes = 250 * 1024^3,
    usar_cache = TRUE,
    cache_path = cache_tmp,
    dry_run_fn = function(sql, billing) stop("não deveria chamar dry-run com cache"),
    query_fn = function(sql, billing, max_bytes) stop("não deveria chamar query com cache")
  )
  expect_equal(res2, brutos_exemplo)
  expect_equal(chamadas_query, 2L)
})

test_that("padronizar_bolsa_familia aplica esquema geobr, remove bolsa_familia 2021-11 e preserva não identificados", {
  resultado <- padronizar_bolsa_familia(brutos_exemplo, municipios_ref)

  expect_identical(names(resultado), colunas_saida)
  expect_type(resultado$ano, "integer")
  expect_type(resultado$mes, "integer")
  expect_type(resultado$code_state, "integer")
  expect_type(resultado$abbrev_state, "character")
  expect_type(resultado$code_muni, "integer")
  expect_type(resultado$name_muni, "character")
  expect_type(resultado$programa, "character")
  expect_type(resultado$qtd_familias, "integer")
  expect_type(resultado$qtd_parcelas, "integer")
  expect_type(resultado$valor_total, "double")
  expect_type(resultado$valor_medio, "double")

  # A linha de bolsa_familia em 2021-11 (valor 18000) deve ter sido removida.
  expect_false(any(resultado$programa == "bolsa_familia" & resultado$ano == 2021L & resultado$mes == 11L))
  expect_equal(nrow(resultado), 4L)

  salvador <- subset(resultado, code_muni == 2927408L & mes == 10L)
  expect_equal(salvador$name_muni, "Salvador")
  expect_equal(salvador$abbrev_state, "BA")
  expect_equal(salvador$code_state, 29L)
  expect_equal(salvador$valor_medio, 200)

  sem_muni_sp <- subset(resultado, code_state == 35L & is.na(code_muni))
  expect_equal(nrow(sem_muni_sp), 1L)
  expect_true(is.na(sem_muni_sp$name_muni))
  expect_equal(sem_muni_sp$abbrev_state, "SP")
  expect_equal(sem_muni_sp$valor_total, 2000)

  uf_desconhecida <- subset(resultado, code_state == 99L)
  expect_equal(nrow(uf_desconhecida), 1L)
  expect_equal(uf_desconhecida$abbrev_state, "NI")
  expect_true(is.na(uf_desconhecida$code_muni))
  expect_true(is.na(uf_desconhecida$name_muni))
  expect_equal(uf_desconhecida$valor_total, 800)

  expect_equal(sum(resultado$valor_total), sum(brutos_exemplo$valor_total) - 18000)
  expect_silent(validar_bolsa_familia(resultado, brutos_exemplo, municipios_ref, exigir_27_ufs = FALSE))
})

test_that("padronizar_bolsa_familia trata retroativos pré-2013, Fernando de Noronha, remoção 2021-11 e integer64", {
  skip_if_not_installed("bit64")
  dados_reais_padrao <- data.frame(
    ano = bit64::as.integer64(c(2012L, 2021L, 2021L, 2021L)),
    mes = bit64::as.integer64(c(12L, 11L, 11L, 11L)),
    programa = c("bolsa_familia", "bolsa_familia", "auxilio_brasil", "novo_bolsa_familia"),
    sigla_uf_fonte = c("PE", "PE", "PE", "MT"),
    id_municipio_fonte = c("2605459", "2605459", "2605459", NA_character_),
    qtd_familias = bit64::as.integer64(c(5L, 17L, 15L, 24L)),
    qtd_parcelas = bit64::as.integer64(c(5L, 17L, 16L, 24L)),
    valor_total = c(1000, 4000, 3800, 15248),
    stringsAsFactors = FALSE
  )

  resultado <- padronizar_bolsa_familia(dados_reais_padrao, municipios_ref, ano_inicial = 2013L)
  expect_equal(nrow(resultado), 2L)
  expect_true(all(resultado$ano == 2021L))
  expect_equal(sum(resultado$code_muni == 2605459L, na.rm = TRUE), 1L)
  expect_equal(unique(resultado$name_muni[!is.na(resultado$code_muni)]), "Fernando de Noronha")
  expect_false(any(resultado$programa == "bolsa_familia" & resultado$ano == 2021L & resultado$mes == 11L))

  mt_na <- subset(resultado, code_state == 51L)
  expect_equal(mt_na$abbrev_state, "MT")
  expect_true(is.na(mt_na$code_muni))
  expect_true(is.na(mt_na$name_muni))
  expect_equal(mt_na$valor_total, 15248)

  expect_silent(validar_bolsa_familia(
    resultado, dados_reais_padrao, municipios_ref, exigir_27_ufs = FALSE, ano_inicial = 2013L
  ))
})

test_that("padronizar_bolsa_familia rejeita códigos IBGE inválidos ou incompatíveis com a UF", {
  inexistente <- brutos_exemplo[1, ]
  inexistente$id_municipio_fonte <- "2999998"
  expect_error(padronizar_bolsa_familia(inexistente, municipios_ref), "Município ausente no geobr")

  formato_ruim <- brutos_exemplo[1, ]
  formato_ruim$id_municipio_fonte <- "292740"
  expect_error(padronizar_bolsa_familia(formato_ruim, municipios_ref), "formato inválido")

  uf_errada <- brutos_exemplo[1, ]
  uf_errada$sigla_uf_fonte <- "SP"
  expect_error(padronizar_bolsa_familia(uf_errada, municipios_ref), "Inconsistência geográfica")
})

test_that("validar_bolsa_familia bloqueia duplicatas, 2021-11 bolsa_familia, lacunas, valores inválidos e divergência", {
  resultado <- padronizar_bolsa_familia(brutos_exemplo, municipios_ref)

  expect_error(
    validar_bolsa_familia(rbind(resultado, resultado[1, ]), brutos_exemplo, municipios_ref, exigir_27_ufs = FALSE),
    "duplicad"
  )

  com_sobreposicao <- resultado
  linha_bf_nov <- resultado[1, ]
  linha_bf_nov$mes <- 11L
  expect_error(
    validar_bolsa_familia(rbind(com_sobreposicao, linha_bf_nov), brutos_exemplo, municipios_ref, exigir_27_ufs = FALSE),
    "Sobreposição indevida.*2021-11"
  )

  com_lacuna <- resultado
  com_lacuna$mes[com_lacuna$mes == 11L] <- 12L
  brutos_lacuna <- brutos_exemplo[brutos_exemplo$mes != 11L | brutos_exemplo$programa != "bolsa_familia", ]
  brutos_lacuna$mes[brutos_lacuna$mes == 11L] <- 12L
  expect_error(
    validar_bolsa_familia(com_lacuna, brutos_lacuna, municipios_ref, exigir_27_ufs = FALSE),
    "Competências ausentes"
  )

  negativo <- resultado
  negativo$valor_total[1] <- -10
  expect_error(
    validar_bolsa_familia(negativo, brutos_exemplo, municipios_ref, exigir_27_ufs = FALSE),
    "negativos"
  )

  zero_fam <- resultado
  zero_fam$qtd_familias[1] <- 0L
  expect_error(
    validar_bolsa_familia(zero_fam, brutos_exemplo, municipios_ref, exigir_27_ufs = FALSE),
    "negativos|nulos"
  )

  total_errado <- resultado
  total_errado$valor_total[1] <- total_errado$valor_total[1] + 50
  expect_error(
    validar_bolsa_familia(total_errado, brutos_exemplo, municipios_ref, exigir_27_ufs = FALSE),
    "Totais reconciliados"
  )

  expect_error(
    validar_bolsa_familia(resultado, brutos_exemplo, municipios_ref, exigir_27_ufs = TRUE),
    "UFs ausentes"
  )
})

test_that("validar_bolsa_familia exige todas as 27 UFs no modo padrão", {
  ufs_27 <- estados_ibge[estados_ibge$code_state != 99L, ]
  muni_27 <- data.frame(
    code_muni = ufs_27$code_state * 100000L + 1001L,
    name_muni = paste("Município", ufs_27$abbrev_state),
    abbrev_state = ufs_27$abbrev_state,
    code_state = ufs_27$code_state,
    stringsAsFactors = FALSE
  )
  brutos_27 <- data.frame(
    ano = 2024L,
    mes = 1L,
    programa = "novo_bolsa_familia",
    sigla_uf_fonte = ufs_27$abbrev_state,
    id_municipio_fonte = as.character(muni_27$code_muni),
    qtd_familias = 10L,
    qtd_parcelas = 10L,
    valor_total = 6000,
    stringsAsFactors = FALSE
  )
  finais_27 <- padronizar_bolsa_familia(brutos_27, muni_27)
  expect_silent(validar_bolsa_familia(finais_27, brutos_27, muni_27, exigir_27_ufs = TRUE))
})

test_that("preparar_asset escreve sempre em tempdir() como Parquet preservando o esquema", {
  skip_if_not_installed("arrow")
  resultado <- padronizar_bolsa_familia(brutos_exemplo, municipios_ref)
  arquivo <- preparar_asset(resultado)
  on.exit(unlink(arquivo), add = TRUE)

  expect_identical(arquivo, file.path(tempdir(), "bolsa_familia_mensal_municipio.parquet"))
  expect_true(file.exists(arquivo))
  expect_false(file.exists(sub("parquet$", "csv", arquivo)))
  lido <- as.data.frame(arrow::read_parquet(arquivo))
  expect_equal(lido, as.data.frame(resultado))
})

test_that("executar respeita --publicar e --usar-cache, valida argumentos e limpa temporário em erro", {
  skip_if_not_installed("bigrquery")
  skip_if_not_installed("geobr")
  skip_if_not_installed("sf")
  skip_if_not_installed("arrow")
  skip_if_not_installed("jsonlite")

  ambiente <- new.env(parent = globalenv())
  sys.source(script, envir = ambiente)

  ufs_27 <- ambiente$estados_ibge[ambiente$estados_ibge$code_state != 99L, ]
  muni_27 <- data.frame(
    code_muni = ufs_27$code_state * 100000L + 1001L,
    name_muni = paste("Município", ufs_27$abbrev_state),
    abbrev_state = ufs_27$abbrev_state,
    code_state = ufs_27$code_state,
    stringsAsFactors = FALSE
  )
  brutos_27 <- data.frame(
    ano = 2024L,
    mes = 1L,
    programa = "novo_bolsa_familia",
    sigla_uf_fonte = ufs_27$abbrev_state,
    id_municipio_fonte = as.character(muni_27$code_muni),
    qtd_familias = 10L,
    qtd_parcelas = 10L,
    valor_total = 6000,
    stringsAsFactors = FALSE
  )

  cache_flags <- logical()
  ambiente$baixar_resumo_bigquery <- function(usar_cache = FALSE) {
    cache_flags <<- c(cache_flags, usar_cache)
    brutos_27
  }
  ambiente$obter_referencia_geobr <- function() muni_27

  publicado <- character()
  ambiente$publicar_asset <- function(arquivo) {
    publicado <<- c(publicado, arquivo)
    invisible(TRUE)
  }

  expect_error(ambiente$executar("--flag-desconhecida"), "Argumento inválido")
  expect_error(ambiente$executar("--sem-cache"), "Argumento inválido")

  arquivo_local <- ambiente$executar(character())
  on.exit(unlink(arquivo_local), add = TRUE)
  expect_identical(arquivo_local, file.path(tempdir(), "bolsa_familia_mensal_municipio.parquet"))
  expect_true(file.exists(arquivo_local))
  expect_length(publicado, 0L)
  expect_identical(cache_flags, FALSE)

  ambiente$executar(c("--usar-cache", "--publicar"))
  expect_identical(publicado, arquivo_local)
  expect_false(file.exists(arquivo_local))
  expect_identical(cache_flags, c(FALSE, TRUE))

  ambiente$publicar_asset <- function(arquivo) {
    conexao <- file(arquivo, "rb")
    stop("Upload falhou na release")
  }
  expect_error(suppressWarnings(ambiente$executar("--publicar")), "Upload falhou na release")
  expect_false(file.exists(arquivo_local))
})
