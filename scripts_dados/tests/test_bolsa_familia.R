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

test_that("montar_query_bolsa_familia gera SQL com as 3 tabelas e métricas esperadas", {
  sql <- montar_query_bolsa_familia(ano_inicial = 2010L)
  expect_type(sql, "character")
  expect_length(sql, 1L)
  expect_match(sql, "basedosdados\\.br_cgu_beneficios_cidadao\\.bolsa_familia_pagamento")
  expect_match(sql, "basedosdados\\.br_cgu_beneficios_cidadao\\.auxilio_brasil")
  expect_match(sql, "basedosdados\\.br_cgu_beneficios_cidadao\\.novo_bolsa_familia")
  expect_match(sql, "'bolsa_familia' AS programa")
  expect_match(sql, "'auxilio_brasil' AS programa")
  expect_match(sql, "'novo_bolsa_familia' AS programa")
  expect_match(sql, "COUNT\\(DISTINCT nis_favorecido\\) AS qtd_beneficiarios")
  expect_match(sql, "COUNT\\(\\*\\) AS qtd_parcelas")
  expect_match(sql, "SUM\\(valor_parcela\\) AS valor_total")
  expect_match(sql, "GROUP BY ano, mes, programa, sigla_uf_fonte, id_municipio_fonte")
  expect_match(sql, ">= 2010")
  expect_error(montar_query_bolsa_familia(2002L), "ano_inicial")
})

test_that("validar_billing_id rejeita placeholder e valores vazios", {
  expect_identical(validar_billing_id("ee-thomasbarros"), "ee-thomasbarros")
  expect_error(validar_billing_id(""), "BILLING_ID.*\\.Renviron")
  expect_error(validar_billing_id("   "), "BILLING_ID.*\\.Renviron")
  expect_error(validar_billing_id("seuprojeto"), "BILLING_ID.*\\.Renviron")
  expect_error(validar_billing_id(NA_character_), "BILLING_ID.*\\.Renviron")
})

test_that("verificar_limite_bytes e baixar_resumo_bigquery aplicam trava de custo e cache", {
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
      billing_id = "ee-thomasbarros",
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

  amostra <- data.frame(
    ano = 2024L,
    mes = 1L,
    programa = "novo_bolsa_familia",
    sigla_uf_fonte = "BA",
    id_municipio_fonte = "2927408",
    qtd_beneficiarios = 10L,
    qtd_parcelas = 10L,
    valor_total = 6000
  )
  res1 <- baixar_resumo_bigquery(
    billing_id = "ee-thomasbarros",
    max_bytes = 250 * 1024^3,
    usar_cache = TRUE,
    cache_path = cache_tmp,
    dry_run_fn = function(sql, billing) 90 * 1024^3,
    query_fn = function(sql, billing, max_bytes) {
      chamadas_query <<- chamadas_query + 1L
      amostra
    }
  )
  expect_equal(chamadas_query, 1L)
  expect_equal(res1, amostra)
  expect_true(file.exists(cache_tmp))

  res2 <- baixar_resumo_bigquery(
    billing_id = "seuprojeto",
    max_bytes = 250 * 1024^3,
    usar_cache = TRUE,
    cache_path = cache_tmp,
    dry_run_fn = function(sql, billing) stop("não deveria chamar dry-run com cache"),
    query_fn = function(sql, billing, max_bytes) stop("não deveria chamar query com cache")
  )
  expect_equal(res2, amostra)
  expect_equal(chamadas_query, 1L)
})
