# Executar da raiz: Rscript scripts_dados/tests/test_rais_estoque.R
if (.Platform$OS.type == "windows") {
  Sys.setlocale("LC_CTYPE", "Portuguese_Brazil.utf8")
}
library(testthat)

script <- if (file.exists("../rais_estoque.R")) {
  "../rais_estoque.R"
} else {
  "scripts_dados/rais_estoque.R"
}
source(script, encoding = "UTF-8")

test_that("SQL da RAIS consulta microdados_vinculos com filtro >= 2009 e contagem de ativos em 31/12", {
  sql <- montar_query_rais_estoque(ano_inicial = 2009L)

  expect_match(sql, "basedosdados\\.br_me_rais\\.microdados_vinculos")
  expect_match(sql, "WHERE ano >= 2009")
  expect_match(sql, "COUNTIF\\(TRIM\\(CAST\\(vinculo_ativo_3112 AS STRING\\)\\) = '1'\\) AS vinculos_ativos")
  expect_match(sql, "GROUP BY ano, sigla_uf_fonte, id_municipio_fonte")
  expect_error(montar_query_rais_estoque(ano_inicial = 1984L), ">= 1985")
  expect_error(montar_query_rais_estoque(ano_inicial = NA_integer_), ">= 1985")
})

test_that("trava de BILLING_ID e limite de bytes no dry-run protegem o custo no BigQuery", {
  expect_error(validar_billing_id(""), "BILLING_ID")
  expect_error(validar_billing_id("seuprojeto"), "BILLING_ID")
  expect_error(validar_billing_id("  SEUPROJETO  "), "BILLING_ID")
  expect_error(validar_billing_id(NA_character_), "BILLING_ID")
  expect_identical(validar_billing_id("meu-projeto"), "meu-projeto")

  limite <- 250 * 1024^3
  expect_true(verificar_limite_bytes(0, max_bytes = limite))
  expect_true(verificar_limite_bytes(27.69 * 1024^3, max_bytes = limite))
  expect_true(verificar_limite_bytes(limite, max_bytes = limite))
  expect_error(
    verificar_limite_bytes(limite + 1024^3, max_bytes = limite),
    "251\\.00 GB.*250\\.00 GB"
  )
  expect_error(verificar_limite_bytes(-1, max_bytes = limite), "inválida")
  expect_error(verificar_limite_bytes(NA_real_, max_bytes = limite), "inválida")

  chamou_query <- FALSE
  expect_error(
    baixar_resumo_rais_bigquery(
      billing_id = "meu-projeto",
      max_bytes = 50 * 1024^3,
      usar_cache = FALSE,
      cache_path = NULL,
      dry_run_fn = function(sql, billing) 80 * 1024^3,
      query_fn = function(sql, billing, max_bytes) {
        chamou_query <<- TRUE
        data.frame()
      }
    ),
    "80\\.00 GB.*50\\.00 GB"
  )
  expect_false(chamou_query)
})

test_that("baixar_resumo_rais_bigquery consulta por padrão e usa cache somente com usar_cache = TRUE", {
  cache_tmp <- tempfile(fileext = ".rds")
  on.exit(unlink(cache_tmp), add = TRUE)

  antigo <- data.frame(
    ano = 2009L,
    sigla_uf_fonte = "AC",
    id_municipio_fonte = "1200401",
    vinculos_ativos = 50L,
    stringsAsFactors = FALSE
  )
  saveRDS(antigo, cache_tmp)

  novo <- data.frame(
    ano = 2009L,
    sigla_uf_fonte = "AC",
    id_municipio_fonte = "1200401",
    vinculos_ativos = 99L,
    stringsAsFactors = FALSE
  )

  chamou_dry <- 0L
  chamou_query <- 0L
  res_padrao <- baixar_resumo_rais_bigquery(
    billing_id = "meu-projeto",
    cache_path = cache_tmp,
    dry_run_fn = function(sql, billing) {
      chamou_dry <<- chamou_dry + 1L
      27 * 1024^3
    },
    query_fn = function(sql, billing, max_bytes) {
      chamou_query <<- chamou_query + 1L
      novo
    }
  )
  expect_identical(chamou_dry, 1L)
  expect_identical(chamou_query, 1L)
  expect_identical(res_padrao$vinculos_ativos, 99L)
  expect_identical(readRDS(cache_tmp)$vinculos_ativos, 99L)

  res_cache <- baixar_resumo_rais_bigquery(
    billing_id = "seuprojeto",
    usar_cache = TRUE,
    cache_path = cache_tmp,
    dry_run_fn = function(sql, billing) stop("não deveria consultar dry_run com cache"),
    query_fn = function(sql, billing, max_bytes) stop("não deveria consultar query com cache")
  )
  expect_identical(res_cache$vinculos_ativos, 99L)
})

municipios_mock <- data.frame(
  code_muni = c(1200401L, 2605459L, 2927408L, 3550308L, 5101837L),
  name_muni = c("Rio Branco", "Fernando de Noronha", "Salvador", "São Paulo", "Boa Esperança do Norte"),
  abbrev_state = c("AC", "PE", "BA", "SP", "MT"),
  code_state = c(12L, 26L, 29L, 35L, 51L),
  stringsAsFactors = FALSE
)

brutos_mock <- data.frame(
  ano = c(2008L, 2009L, 2009L, 2009L, 2009L, 2009L, 2010L, 2010L),
  sigla_uf_fonte = c("AC", "AC", "PE", "SP", "MT", NA, "BA", "SP"),
  id_municipio_fonte = c("1200401", "1200401", "260545", "359999", "5101837", "{ñ class}", "2927408", "3550308"),
  vinculos_ativos = c(500, 1200, 350, 42, 0, 15, 8000, 25000),
  stringsAsFactors = FALSE
)

test_that("padronizar_rais_estoque reconcilia 6 e 7 dígitos no geobr, filtra >= 2009 e preserva 0 e NA", {
  res <- padronizar_rais_estoque(brutos_mock, municipios_mock, ano_inicial = 2009L)

  expect_identical(
    names(res),
    c("ano", "code_state", "abbrev_state", "code_muni", "name_muni", "vinculos_ativos")
  )
  expect_type(res$ano, "integer")
  expect_type(res$code_state, "integer")
  expect_type(res$abbrev_state, "character")
  expect_type(res$code_muni, "integer")
  expect_type(res$name_muni, "character")
  expect_type(res$vinculos_ativos, "integer")
  expect_true(all(res$ano >= 2009L))

  fn <- subset(res, code_muni == 2605459L)
  expect_identical(nrow(fn), 1L)
  expect_identical(fn$name_muni, "Fernando de Noronha")
  expect_identical(fn$code_state, 26L)
  expect_identical(fn$vinculos_ativos, 350L)

  zero_row <- subset(res, code_muni == 5101837L)
  expect_identical(zero_row$vinculos_ativos, 0L)
  expect_identical(zero_row$name_muni, "Boa Esperança do Norte")

  sp_ign <- subset(res, ano == 2009L & code_state == 35L)
  expect_identical(nrow(sp_ign), 1L)
  expect_true(is.na(sp_ign$code_muni))
  expect_true(is.na(sp_ign$name_muni))
  expect_identical(sp_ign$abbrev_state, "SP")
  expect_identical(sp_ign$vinculos_ativos, 42L)

  ni_row <- subset(res, code_state == 99L)
  expect_identical(nrow(ni_row), 1L)
  expect_identical(ni_row$abbrev_state, "NI")
  expect_true(is.na(ni_row$code_muni))
  expect_true(is.na(ni_row$name_muni))
  expect_identical(ni_row$vinculos_ativos, 15L)

  expect_true(validar_rais_estoque(res, brutos_mock, municipios_mock, exigir_27_ufs = FALSE))
})

test_that("padronizar_rais_estoque consolida múltiplas sentinelas de município ausente e converte integer64", {
  skip_if_not_installed("bit64")
  brutos_sent <- data.frame(
    ano = c(2009L, 2009L, 2009L, 2009L),
    sigla_uf_fonte = c("SP", "SP", "SP", ""),
    id_municipio_fonte = c("", "0000000", "359999", "9999999"),
    vinculos_ativos = bit64::as.integer64(c(10, 20, 30, 5)),
    stringsAsFactors = FALSE
  )
  res <- padronizar_rais_estoque(brutos_sent, municipios_mock, ano_inicial = 2009L)

  expect_identical(nrow(res), 2L)
  expect_identical(subset(res, code_state == 35L)$vinculos_ativos, 60L)
  expect_identical(subset(res, code_state == 99L)$vinculos_ativos, 5L)
  expect_true(validar_rais_estoque(res, brutos_sent, municipios_mock, exigir_27_ufs = FALSE))
})

test_that("padronizar_rais_estoque rejeita códigos IBGE inválidos, inexistentes ou incompatíveis com UF", {
  invalido_fmt <- data.frame(
    ano = 2009L, sigla_uf_fonte = "BA", id_municipio_fonte = "29274", vinculos_ativos = 10L,
    stringsAsFactors = FALSE
  )
  expect_error(padronizar_rais_estoque(invalido_fmt, municipios_mock), "formato inválido")

  inexistente <- data.frame(
    ano = 2009L, sigla_uf_fonte = "BA", id_municipio_fonte = "2999991", vinculos_ativos = 10L,
    stringsAsFactors = FALSE
  )
  expect_error(padronizar_rais_estoque(inexistente, municipios_mock), "ausente no geobr")

  uf_errada <- data.frame(
    ano = 2009L, sigla_uf_fonte = "SP", id_municipio_fonte = "2927408", vinculos_ativos = 10L,
    stringsAsFactors = FALSE
  )
  expect_error(padronizar_rais_estoque(uf_errada, municipios_mock), "Inconsistência geográfica")
})

test_that("validar_rais_estoque barra duplicatas, negativos, buraco anual, UF faltante e erro de reconciliação", {
  res <- padronizar_rais_estoque(brutos_mock, municipios_mock, ano_inicial = 2009L)

  expect_error(
    validar_rais_estoque(rbind(res, res[1, ]), brutos_mock, municipios_mock, exigir_27_ufs = FALSE),
    "duplicad"
  )

  neg <- res
  neg$vinculos_ativos[1] <- -1L
  expect_error(
    validar_rais_estoque(neg, brutos_mock, municipios_mock, exigir_27_ufs = FALSE),
    "negativ"
  )

  na_val <- res
  na_val$vinculos_ativos[1] <- NA_integer_
  expect_error(
    validar_rais_estoque(na_val, brutos_mock, municipios_mock, exigir_27_ufs = FALSE),
    "ausent"
  )

  buraco_brutos <- data.frame(
    ano = c(2009L, 2011L),
    sigla_uf_fonte = c("AC", "AC"),
    id_municipio_fonte = c("1200401", "1200401"),
    vinculos_ativos = c(100L, 120L),
    stringsAsFactors = FALSE
  )
  buraco_res <- padronizar_rais_estoque(buraco_brutos, municipios_mock, ano_inicial = 2009L)
  expect_error(
    validar_rais_estoque(buraco_res, buraco_brutos, municipios_mock, exigir_27_ufs = FALSE),
    "Anos ausentes"
  )

  expect_error(
    validar_rais_estoque(res, brutos_mock, municipios_mock, exigir_27_ufs = TRUE),
    "UFs ausentes"
  )

  divergente <- res
  divergente$vinculos_ativos[1] <- divergente$vinculos_ativos[1] + 1L
  expect_error(
    validar_rais_estoque(divergente, brutos_mock, municipios_mock, exigir_27_ufs = FALSE),
    "Totais reconciliados"
  )

  nome_errado <- res
  nome_errado$name_muni[1] <- "Nome Inventado"
  expect_error(
    validar_rais_estoque(nome_errado, brutos_mock, municipios_mock, exigir_27_ufs = FALSE),
    "geográficos municipais"
  )
})

test_that("preparar_asset escreve Parquet válido exclusivamente em tempdir()", {
  res <- padronizar_rais_estoque(brutos_mock, municipios_mock, ano_inicial = 2009L)
  caminho <- preparar_asset(res)
  on.exit(unlink(caminho), add = TRUE)

  expect_identical(basename(caminho), "rais_estoque_anual_municipio.parquet")
  expect_identical(
    normalizePath(dirname(caminho), winslash = "/"),
    normalizePath(tempdir(), winslash = "/")
  )
  expect_true(file.exists(caminho))

  lido <- arrow::read_parquet(caminho)
  expect_identical(nrow(lido), nrow(res))
  expect_identical(names(lido), names(res))
  expect_identical(as.integer(lido$vinculos_ativos), as.integer(res$vinculos_ativos))
})

test_that("executar rejeita argumentos inválidos e apaga Parquet temporário em --publicar mesmo sob falha", {
  expect_error(executar(c("--invalido")), "Argumento inválido")

  skip_if_not_installed("bigrquery")
  skip_if_not_installed("piggyback")
  skip_if_not_installed("gh")
  skip_if_not_installed("httr")

  env_orig <- list(
    baixar = baixar_resumo_rais_bigquery,
    geobr = obter_referencia_geobr,
    validar = validar_rais_estoque,
    publicar = publicar_asset
  )
  on.exit({
    assign("baixar_resumo_rais_bigquery", env_orig$baixar, envir = .GlobalEnv)
    assign("obter_referencia_geobr", env_orig$geobr, envir = .GlobalEnv)
    assign("validar_rais_estoque", env_orig$validar, envir = .GlobalEnv)
    assign("publicar_asset", env_orig$publicar, envir = .GlobalEnv)
  }, add = TRUE)

  usar_cache_recebido <- NA
  assign("baixar_resumo_rais_bigquery", function(usar_cache = FALSE, ...) {
    usar_cache_recebido <<- usar_cache
    brutos_mock
  }, envir = .GlobalEnv)
  assign("obter_referencia_geobr", function() municipios_mock, envir = .GlobalEnv)
  assign("validar_rais_estoque", function(dados_finais, dados_brutos, municipios_geobr, ...) {
    env_orig$validar(dados_finais, dados_brutos, municipios_geobr, exigir_27_ufs = FALSE)
  }, envir = .GlobalEnv)
  assign("publicar_asset", function(arquivo) stop("falha simulada de upload"), envir = .GlobalEnv)

  destino <- file.path(tempdir(), asset_nome)
  unlink(destino)

  expect_error(executar(c("--publicar")), "falha simulada de upload")
  expect_false(usar_cache_recebido)
  expect_false(file.exists(destino))

  arq_local <- executar(c("--usar-cache"))
  on.exit(unlink(arq_local), add = TRUE)
  expect_true(usar_cache_recebido)
  expect_true(file.exists(arq_local))
})

test_that("regressão da auditoria real: zeros observados, ausências sem preenchimento, NI e 5.571 municípios", {
  municipios_audit <- data.frame(
    code_muni = c(2106359L, 2111672L, 2204550L, 2605459L, 5101837L),
    name_muni = c(
      "Marajá do Sena", "São Roberto", "Guaribas",
      "Fernando de Noronha", "Boa Esperança do Norte"
    ),
    abbrev_state = c("MA", "MA", "PI", "PE", "MT"),
    code_state = c(21L, 21L, 22L, 26L, 51L),
    stringsAsFactors = FALSE
  )

  # Espelha achados auditados em 2009-2025:
  # - São Roberto (2111672) ausente na fonte em 2009 e presente a partir de 2010
  # - Guaribas (2204550) com 0 vínculos ativos observados em 2010
  # - Marajá do Sena (2106359) com 0 vínculos ativos observados em 2015 (aqui 2011 na sequência)
  # - Fernando de Noronha (2605459) presente em todos os anos e Boa Esperança do Norte (5101837) em 2011
  # - Registro NI (sigla_uf = NA, id_municipio = "999999") preservado como 99/"NI" com 3066 vínculos
  brutos_audit <- data.frame(
    ano = c(2009L, 2009L, 2010L, 2010L, 2010L, 2011L, 2011L, 2011L, 2011L),
    sigla_uf_fonte = c("PE", "PI", "MA", "PI", "PE", "MA", "PE", "MT", NA),
    id_municipio_fonte = c("2605459", "2204550", "2111672", "2204550", "2605459", "2106359", "2605459", "5101837", "999999"),
    vinculos_ativos = c(1025L, 120L, 180L, 0L, 1049L, 0L, 1102L, 143L, 3066L),
    stringsAsFactors = FALSE
  )

  res <- padronizar_rais_estoque(brutos_audit, municipios_audit, ano_inicial = 2009L)

  expect_identical(nrow(res), 9L)
  expect_identical(nrow(subset(res, ano == 2009L & code_muni == 2111672L)), 0L)
  expect_identical(subset(res, ano == 2010L & code_muni == 2204550L)$vinculos_ativos, 0L)
  expect_identical(subset(res, ano == 2011L & code_muni == 2106359L)$vinculos_ativos, 0L)
  expect_identical(subset(res, ano == 2011L & code_muni == 5101837L)$vinculos_ativos, 143L)
  expect_identical(subset(res, ano == 2011L & code_state == 99L)$abbrev_state, "NI")
  expect_identical(subset(res, ano == 2011L & code_state == 99L)$vinculos_ativos, 3066L)
  expect_true(is.na(subset(res, ano == 2011L & code_state == 99L)$code_muni))
  expect_true(validar_rais_estoque(res, brutos_audit, municipios_audit, exigir_27_ufs = FALSE))
})
