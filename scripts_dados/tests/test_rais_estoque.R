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
