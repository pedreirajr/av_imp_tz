# Executar da raiz: Rscript scripts_dados/bolsa_familia.R
# Gera bolsa_familia_mensal_municipio.parquet em tempdir() durante a sessão R.
# Publicar e apagar o temporário: Rscript scripts_dados/bolsa_familia.R --publicar
# Forçar nova consulta no BigQuery ignorando cache local: --sem-cache
# Dependências: bigrquery, dplyr, geobr, arrow, jsonlite;
# Publicação: piggyback, gh e httr, com autenticação do GitHub.
#
# Pagamentos mensais do Bolsa Família e do Auxílio Brasil por município a partir
# da tabela tratada da CGU / Portal da Transparência na Base dos Dados
# (basedosdados.br_cgu_beneficios_cidadao):
# - bolsa_familia_pagamento (2013-01 a 2021-11)
# - auxilio_brasil (2021-11 a 2023-02, Lei n. 14.284/2021)
# - novo_bolsa_familia (2023-03 em diante, Lei n. 14.601/2023)
#
# O projeto usa a Base dos Dados / BigQuery porque o pacote owdbr (2019) aponta
# para uma URL legada do Portal da Transparência bloqueada por WAF (HTTP 405) e
# sem suporte a chave-api-dados, e a API MI Social do MDS (misocialr) encontrava-se
# em manutenção preventiva de segurança (gov.br/mds/pt-br/avisos).
#
# Configure BILLING_ID no arquivo .Renviron na raiz do projeto (nunca versionado)
# com o ID do seu projeto Google Cloud (BigQuery Sandbox ou conta gratuita, cota
# mensal de 1 TB). Antes de executar qualquer query real, o script executa um
# dry-run gratuito e bloqueia a execução se a estimativa ultrapassar 250 GB.
#
# Fonte oficial primária: https://portaldatransparencia.gov.br/download-de-dados/novo-bolsa-familia
# Catálogo Base dos Dados: https://basedosdados.org/dataset/br-cgu-beneficios-cidadao

repo <- "pedreirajr/av_imp_tz"
release_tag <- "data"
asset_nome <- "bolsa_familia_mensal_municipio.parquet"
ano_inicial_padrao <- 2010L
limite_bytes_padrao <- 250 * 1024^3 # 250 GB (limite de segurança dentro de 1 TB/mês gratuito)

tabelas_pbf <- c(
  bolsa_familia = "basedosdados.br_cgu_beneficios_cidadao.bolsa_familia_pagamento",
  auxilio_brasil = "basedosdados.br_cgu_beneficios_cidadao.auxilio_brasil",
  novo_bolsa_familia = "basedosdados.br_cgu_beneficios_cidadao.novo_bolsa_familia"
)

validar_billing_id <- function(billing_id) {
  valor <- if (is.null(billing_id) || !length(billing_id)) "" else trimws(as.character(billing_id)[1])
  if (is.na(valor) || !nzchar(valor) || identical(tolower(valor), "seuprojeto")) {
    stop(
      "BILLING_ID não configurado. Defina BILLING_ID=<seu-project-id> no arquivo .Renviron na raiz do projeto.",
      call. = FALSE
    )
  }
  valor
}

verificar_limite_bytes <- function(bytes_estimados, max_bytes = limite_bytes_padrao) {
  bytes <- suppressWarnings(as.numeric(bytes_estimados)[1])
  limite <- suppressWarnings(as.numeric(max_bytes)[1])
  if (is.na(bytes) || !is.finite(bytes) || bytes < 0) {
    stop("Estimativa de bytes do BigQuery inválida ou ausente.", call. = FALSE)
  }
  if (is.na(limite) || !is.finite(limite) || limite <= 0) {
    stop("Limite máximo de bytes inválido.", call. = FALSE)
  }
  if (bytes > limite) {
    stop(
      sprintf(
        "Consulta bloqueada pela trava de custo: estimativa de %.2f GB excede o limite de %.2f GB.",
        bytes / (1024^3),
        limite / (1024^3)
      ),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

montar_query_bolsa_familia <- function(ano_inicial = ano_inicial_padrao) {
  ano_min <- suppressWarnings(as.integer(ano_inicial)[1])
  if (is.na(ano_min) || ano_min < 2003L) {
    stop("ano_inicial deve ser um inteiro >= 2003.", call. = FALSE)
  }

  subconsultas <- mapply(
    function(programa, tabela) {
      sprintf(
        paste(
          "  SELECT",
          "    CAST(ano_competencia AS INT64) AS ano,",
          "    CAST(mes_competencia AS INT64) AS mes,",
          "    UPPER(TRIM(CAST(sigla_uf AS STRING))) AS sigla_uf_fonte,",
          "    TRIM(CAST(id_municipio AS STRING)) AS id_municipio_fonte,",
          "    '%s' AS programa,",
          "    NULLIF(TRIM(CAST(nis_favorecido AS STRING)), '') AS nis_favorecido,",
          "    CAST(valor_parcela AS FLOAT64) AS valor_parcela",
          "  FROM `%s`",
          "  WHERE CAST(ano_competencia AS INT64) >= %d",
          sep = "\n"
        ),
        programa,
        tabela,
        ano_min
      )
    },
    names(tabelas_pbf),
    unname(tabelas_pbf),
    SIMPLIFY = TRUE,
    USE.NAMES = FALSE
  )

  paste0(
    "WITH base AS (\n",
    paste(subconsultas, collapse = "\n\n  UNION ALL\n\n"),
    "\n)\n",
    "SELECT\n",
    "  ano,\n",
    "  mes,\n",
    "  programa,\n",
    "  sigla_uf_fonte,\n",
    "  id_municipio_fonte,\n",
    "  COUNT(DISTINCT nis_favorecido) AS qtd_beneficiarios,\n",
    "  COUNT(*) AS qtd_parcelas,\n",
    "  SUM(valor_parcela) AS valor_total\n",
    "FROM base\n",
    "WHERE valor_parcela IS NOT NULL\n",
    "GROUP BY ano, mes, programa, sigla_uf_fonte, id_municipio_fonte"
  )
}

caminho_cache_padrao <- function(ano_inicial = ano_inicial_padrao) {
  dir_cache <- tools::R_user_dir("av_imp_tz_bolsa_familia", "cache")
  file.path(dir_cache, sprintf("resumo_pbf_bq_%d.rds", as.integer(ano_inicial)))
}

executar_dry_run_bq <- function(sql, billing_id) {
  as.numeric(bigrquery::bq_perform_query_dry_run(query = sql, billing = billing_id))
}

executar_query_bq <- function(sql, billing_id, max_bytes = limite_bytes_padrao) {
  tabela_tmp <- bigrquery::bq_project_query(
    x = billing_id,
    query = sql,
    configuration = list(
      query = list(
        maximum_bytes_billed = jsonlite::unbox(sprintf("%.0f", max_bytes))
      )
    )
  )
  bigrquery::bq_table_download(tabela_tmp, bigint = "integer64")
}

baixar_resumo_bigquery <- function(
  billing_id = Sys.getenv("BILLING_ID", "seuprojeto"),
  ano_inicial = ano_inicial_padrao,
  max_bytes = limite_bytes_padrao,
  usar_cache = TRUE,
  cache_path = caminho_cache_padrao(ano_inicial),
  dry_run_fn = executar_dry_run_bq,
  query_fn = executar_query_bq
) {
  if (isTRUE(usar_cache) && file.exists(cache_path)) {
    message("Carregando resumo agregado do cache local: ", cache_path)
    return(readRDS(cache_path))
  }

  billing <- validar_billing_id(billing_id)
  sql <- montar_query_bolsa_familia(ano_inicial = ano_inicial)

  message("Executando dry-run gratuito no BigQuery para validar volume de bytes...")
  bytes_estimados <- dry_run_fn(sql, billing)
  verificar_limite_bytes(bytes_estimados, max_bytes = max_bytes)
  message(sprintf(
    "Dry-run aprovado: %.2f GB estimados (limite: %.2f GB).",
    bytes_estimados / (1024^3),
    max_bytes / (1024^3)
  ))

  dados_brutos <- query_fn(sql, billing, max_bytes = max_bytes)

  if (!is.null(cache_path) && nzchar(cache_path)) {
    dir.create(dirname(cache_path), recursive = TRUE, showWarnings = FALSE)
    saveRDS(dados_brutos, cache_path)
  }

  dados_brutos
}
