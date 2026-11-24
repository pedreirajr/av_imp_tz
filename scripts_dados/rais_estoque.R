# Executar da raiz: Rscript scripts_dados/rais_estoque.R
# Gera rais_estoque_anual_municipio.parquet em tempdir() durante a sessão R.
# Publicar e apagar o temporário: Rscript scripts_dados/rais_estoque.R --publicar
# Reaproveitar cache local da última consulta BigQuery: --usar-cache
# Dependências: bigrquery, dplyr, geobr, sf, arrow, jsonlite;
# Publicação: piggyback, gh e httr, com autenticação do GitHub.
#
# Estoque anual de vínculos empregatícios formais ativos em 31 de dezembro por
# município, a partir dos microdados da RAIS (MTE/PDET) consolidados na Base dos
# Dados (basedosdados.br_me_rais.microdados_vinculos), desde o ano-base 2009.
#
# O recorte inicial em 2009 fornece o estoque em 31/12/2009 como denominador
# pré-período (t - 1) para calcular taxas percentuais mensais dos fluxos do
# CAGED municipal (caged_movimentacoes_mensais.parquet, iniciado em 2010-01).
#
# A extração usa BigQuery / Base dos Dados em vez do download direto via raisr
# no FTP do MTE porque a série 2009-2025 soma 295 arquivos .7z (38,37 GB) a
# ~0,62-0,90 MB/s no FTP (~18-25 horas locais), enquanto a agregação server-side
# no BigQuery cobre exatamente 2009-2025 sem RLS em ~20 segundos (~28 GB dentro
# da franquia gratuita de 1 TB/mês) e reconcilia com zero diferença contra o FTP.
#
# Configure BILLING_ID no arquivo .Renviron na raiz do projeto (nunca versionado)
# com o ID do seu projeto Google Cloud (BigQuery Sandbox ou conta gratuita).
# Antes de executar qualquer query real, o script executa um dry-run gratuito e
# impõe trava de 250 GB no cliente e no servidor (maximumBytesBilled).
#
# Fonte oficial primária: https://www.gov.br/trabalho-e-emprego/pt-br/acesso-a-informacao/acoes-e-programas/programas-projetos-acoes-obras-e-atividades/estatisticas-trabalho/microdados-rais-e-caged
# Catálogo Base dos Dados: https://basedosdados.org/dataset/br-me-rais

repo <- "pedreirajr/av_imp_tz"
release_tag <- "data"
asset_nome <- "rais_estoque_anual_municipio.parquet"
ano_inicial_padrao <- 2009L
limite_bytes_padrao <- 250 * 1024^3 # 250 GB (limite de segurança dentro de 1 TB/mês gratuito)
tabela_rais_bq <- "basedosdados.br_me_rais.microdados_vinculos"

estados_ibge <- data.frame(
  code_state = c(11:17, 21:29, 31:33, 35L, 41:43, 50:53, 99L),
  abbrev_state = c(
    "RO", "AC", "AM", "RR", "PA", "AP", "TO",
    "MA", "PI", "CE", "RN", "PB", "PE", "AL", "SE", "BA",
    "MG", "ES", "RJ", "SP",
    "PR", "SC", "RS",
    "MS", "MT", "GO", "DF",
    "NI"
  ),
  stringsAsFactors = FALSE
)

colunas_saida <- c(
  "ano", "code_state", "abbrev_state", "code_muni", "name_muni",
  "vinculos_ativos"
)

# 1. CAMADA BIGQUERY (SQL, TRAVA DE CUSTO E CACHE OPT-IN)

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

montar_query_rais_estoque <- function(ano_inicial = ano_inicial_padrao) {
  ano_min <- suppressWarnings(as.integer(ano_inicial)[1])
  if (is.na(ano_min) || ano_min < 1985L) {
    stop("ano_inicial deve ser um inteiro >= 1985.", call. = FALSE)
  }

  sprintf(
    paste(
      "SELECT",
      "  CAST(ano AS INT64) AS ano,",
      "  UPPER(TRIM(CAST(sigla_uf AS STRING))) AS sigla_uf_fonte,",
      "  TRIM(CAST(id_municipio AS STRING)) AS id_municipio_fonte,",
      "  COUNTIF(TRIM(CAST(vinculo_ativo_3112 AS STRING)) = '1') AS vinculos_ativos",
      "FROM `%s`",
      "WHERE ano >= %d",
      "GROUP BY ano, sigla_uf_fonte, id_municipio_fonte",
      sep = "\n"
    ),
    tabela_rais_bq,
    ano_min
  )
}

caminho_cache_padrao <- function(ano_inicial = ano_inicial_padrao) {
  dir_cache <- tools::R_user_dir("av_imp_tz_rais_estoque", "cache")
  file.path(dir_cache, sprintf("resumo_rais_bq_%d.rds", as.integer(ano_inicial)))
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
  bigrquery::bq_table_download(tabela_tmp, bigint = "numeric")
}

baixar_resumo_rais_bigquery <- function(
  billing_id = Sys.getenv("BILLING_ID", "seuprojeto"),
  ano_inicial = ano_inicial_padrao,
  max_bytes = limite_bytes_padrao,
  usar_cache = FALSE,
  cache_path = caminho_cache_padrao(ano_inicial),
  dry_run_fn = executar_dry_run_bq,
  query_fn = executar_query_bq
) {
  if (isTRUE(usar_cache) && !is.null(cache_path) && file.exists(cache_path)) {
    data_cache <- format(file.info(cache_path)$mtime, "%Y-%m-%d %H:%M:%S")
    message("Carregando resumo agregado do cache local (--usar-cache, gerado em ", data_cache, "): ", cache_path)
    return(readRDS(cache_path))
  }

  billing <- validar_billing_id(billing_id)
  sql <- montar_query_rais_estoque(ano_inicial = ano_inicial)

  message("Executando dry-run gratuito no BigQuery para validar sintaxe e volume de bytes...")
  bytes_estimados <- dry_run_fn(sql, billing)
  if (length(bytes_estimados) == 0L) {
    message(sprintf(
      "Dry-run aprovado (estimativa de bytes omitida pelo BigQuery por Row-Level Security; trava server-side ativa em %.2f GB).",
      max_bytes / (1024^3)
    ))
  } else {
    verificar_limite_bytes(bytes_estimados, max_bytes = max_bytes)
    message(sprintf(
      "Dry-run aprovado: %.2f GB estimados (limite: %.2f GB).",
      bytes_estimados / (1024^3),
      max_bytes / (1024^3)
    ))
  }

  dados_brutos <- query_fn(sql, billing, max_bytes = max_bytes)

  if (!is.null(cache_path) && nzchar(cache_path)) {
    dir.create(dirname(cache_path), recursive = TRUE, showWarnings = FALSE)
    saveRDS(dados_brutos, cache_path)
  }

  dados_brutos
}
