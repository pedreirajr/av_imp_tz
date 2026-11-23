# Executar da raiz: Rscript scripts_dados/bolsa_familia.R
# Gera bolsa_familia_mensal_municipio.parquet em tempdir() durante a sessão R.
# Publicar e apagar o temporário: Rscript scripts_dados/bolsa_familia.R --publicar
# Forçar nova consulta no BigQuery ignorando cache local: --sem-cache
# Dependências: bigrquery, dplyr, geobr, sf, arrow, jsonlite;
# Publicação: piggyback, gh e httr, com autenticação do GitHub.
#
# Pagamentos mensais do Bolsa Família e do Auxílio Brasil por município a partir
# da tabela tratada da CGU / Portal da Transparência na Base dos Dados
# (basedosdados.br_cgu_beneficios_cidadao):
# - bolsa_familia_pagamento (competências completas de 2013-01 a 2021-11)
# - auxilio_brasil (competências completas de 2021-11 a 2023-02, Lei n. 14.284/2021;
#   inclui parcelas retroativas de 2020-08 e 2021-03 a 2021-10)
# - novo_bolsa_familia (competências completas a partir de 2023-03, Lei n. 14.601/2023;
#   na camada aberta da Base dos Dados, disponível até 2026-04 devido a Row-Level Security)
#
# A série inicia em 2013-01 porque a CGU passou a disponibilizar as folhas mensais
# nesse período; parcelas retroativas de 2012-02 a 2012-12 pagas na folha de 2013
# são parciais (82 a 3.936 municípios) e ficam fora do corte >= 2013.
# Em 2021-11 há sobreposição de competência entre bolsa_familia e auxilio_brasil;
# a coluna programa diferencia os registros para evitar dupla contagem.
#
# O projeto usa a Base dos Dados / BigQuery porque o pacote owdbr (2019) aponta
# para uma URL legada do Portal da Transparência bloqueada por WAF (HTTP 405) e
# sem suporte a chave-api-dados, e a API MI Social do MDS (misocialr) encontrava-se
# em manutenção preventiva de segurança (gov.br/mds/pt-br/avisos).
#
# Configure BILLING_ID no arquivo .Renviron na raiz do projeto (nunca versionado)
# com o ID do seu projeto Google Cloud (BigQuery Sandbox ou conta gratuita, cota
# mensal de 1 TB). Antes de executar qualquer query real, o script executa um
# dry-run gratuito e impõe trava de 250 GB no cliente e no servidor (maximumBytesBilled).
#
# Fonte oficial primária: https://portaldatransparencia.gov.br/download-de-dados/novo-bolsa-familia
# Catálogo Base dos Dados: https://basedosdados.org/dataset/br-cgu-beneficios-cidadao

repo <- "pedreirajr/av_imp_tz"
release_tag <- "data"
asset_nome <- "bolsa_familia_mensal_municipio.parquet"
ano_inicial_padrao <- 2013L
limite_bytes_padrao <- 250 * 1024^3 # 250 GB (limite de segurança dentro de 1 TB/mês gratuito)

tabelas_pbf <- c(
  bolsa_familia = "basedosdados.br_cgu_beneficios_cidadao.bolsa_familia_pagamento",
  auxilio_brasil = "basedosdados.br_cgu_beneficios_cidadao.auxilio_brasil",
  novo_bolsa_familia = "basedosdados.br_cgu_beneficios_cidadao.novo_bolsa_familia"
)

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
  "ano", "mes", "code_state", "abbrev_state", "code_muni", "name_muni",
  "programa", "qtd_beneficiarios", "qtd_parcelas", "valor_total", "valor_medio"
)

# 1. CAMADA BIGQUERY (SQL, TRAVA DE CUSTO E CACHE)

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
  bigrquery::bq_table_download(tabela_tmp, bigint = "numeric")
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
  if (isTRUE(usar_cache) && !is.null(cache_path) && file.exists(cache_path)) {
    message("Carregando resumo agregado do cache local: ", cache_path)
    return(readRDS(cache_path))
  }

  billing <- validar_billing_id(billing_id)
  sql <- montar_query_bolsa_familia(ano_inicial = ano_inicial)

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

# 2. REFERÊNCIA GEOGRÁFICA (GEOBR) E PADRONIZAÇÃO

obter_referencia_geobr <- function() {
  message("Carregando tabela de referência municipal do geobr (2022)...")
  # read_municipality(2022) traz Fernando de Noronha (2605459), ausente em lookup_muni(2022);
  # lookup_muni(2022) traz Boa Esperança do Norte (5101837), ausente em read_municipality(2022).
  # A união dos dois garante cobertura completa das 5.571 unidades oficiais do geobr.
  malha <- geobr::read_municipality(year = 2022, simplified = TRUE, showProgress = FALSE) |>
    sf::st_drop_geometry() |>
    dplyr::transmute(
      code_muni = as.integer(code_muni),
      name_muni = as.character(name_muni),
      abbrev_state = as.character(abbrev_state),
      code_state = as.integer(code_state)
    )

  tabela <- geobr::lookup_muni(year = 2022, name_muni = "all") |>
    dplyr::transmute(
      code_muni = as.integer(code_muni),
      name_muni = as.character(name_muni),
      abbrev_state = as.character(abbrev_state),
      code_state = as.integer(code_state)
    )

  muni <- dplyr::bind_rows(malha, tabela) |>
    dplyr::distinct(code_muni, .keep_all = TRUE)

  if (nrow(muni) < 5570L || anyNA(muni) || anyDuplicated(muni$code_muni) ||
      any(nchar(muni$code_muni) != 7L)) {
    stop("Tabela de referência do geobr inválida ou incompleta.", call. = FALSE)
  }
  muni
}

codigo_municipio_ausente <- function(x) {
  limpo <- trimws(as.character(x))
  is.na(limpo) | limpo %in% c("", "0", "000000", "0000000", "999999", "9999999")
}

para_numerico_seguro <- function(x) {
  if (inherits(x, "integer64")) {
    if (!requireNamespace("bit64", quietly = TRUE)) {
      stop("Instale o pacote bit64 para converter colunas integer64.", call. = FALSE)
    }
    return(as.double(x))
  }
  suppressWarnings(as.numeric(x))
}

converter_inteiro_seguro <- function(x, nome_campo) {
  num <- para_numerico_seguro(x)
  if (anyNA(num) || any(!is.finite(num)) || any(num != floor(num)) ||
      any(num > .Machine$integer.max) || any(num < -.Machine$integer.max)) {
    stop("Valores inválidos para conversão inteira em ", nome_campo, ".", call. = FALSE)
  }
  as.integer(num)
}

padronizar_bolsa_familia <- function(dados_brutos, municipios_geobr, ano_inicial = ano_inicial_padrao) {
  esperadas <- c(
    "ano", "mes", "programa", "sigla_uf_fonte", "id_municipio_fonte",
    "qtd_beneficiarios", "qtd_parcelas", "valor_total"
  )
  faltando <- setdiff(esperadas, names(dados_brutos))
  if (length(faltando)) {
    stop("Colunas obrigatórias ausentes na consulta bruta: ", paste(faltando, collapse = ", "), call. = FALSE)
  }

  dados <- as.data.frame(dados_brutos, stringsAsFactors = FALSE)
  dados$ano <- converter_inteiro_seguro(dados$ano, "ano")
  dados$mes <- converter_inteiro_seguro(dados$mes, "mes")
  dados <- dados[dados$ano >= as.integer(ano_inicial), , drop = FALSE]

  if (!nrow(dados)) {
    stop("Consulta bruta não retornou registros no período >= ", ano_inicial, ".", call. = FALSE)
  }

  cod_txt <- trimws(as.character(dados$id_municipio_fonte))
  ausente <- codigo_municipio_ausente(cod_txt)
  cod_txt[ausente] <- NA_character_

  nao_ausente <- !is.na(cod_txt)
  if (any(nao_ausente & !grepl("^[0-9]{7}$", cod_txt))) {
    invalidos <- unique(cod_txt[nao_ausente & !grepl("^[0-9]{7}$", cod_txt)])
    stop(
      "Código de município com formato inválido (esperado 7 dígitos IBGE): ",
      paste(utils::head(invalidos, 10), collapse = ", "),
      call. = FALSE
    )
  }

  cod_int <- suppressWarnings(as.integer(cod_txt))
  inexistentes <- setdiff(unique(cod_int[!is.na(cod_int)]), municipios_geobr$code_muni)
  if (length(inexistentes)) {
    stop(
      "Município ausente no geobr (2022): ",
      paste(utils::head(inexistentes, 10), collapse = ", "),
      call. = FALSE
    )
  }

  uf_fonte <- toupper(trimws(as.character(dados$sigla_uf_fonte)))
  ufs_validas <- estados_ibge$abbrev_state[estados_ibge$code_state != 99L]
  uf_fonte[is.na(uf_fonte) | !uf_fonte %in% ufs_validas] <- "NI"
  code_state_fonte <- estados_ibge$code_state[match(uf_fonte, estados_ibge$abbrev_state)]

  idx_geo <- match(cod_int, municipios_geobr$code_muni)
  tem_muni <- !is.na(cod_int)

  code_state_final <- ifelse(tem_muni, municipios_geobr$code_state[idx_geo], code_state_fonte)
  abbrev_state_final <- ifelse(tem_muni, municipios_geobr$abbrev_state[idx_geo], uf_fonte)
  name_muni_final <- ifelse(tem_muni, municipios_geobr$name_muni[idx_geo], NA_character_)

  # Verifica divergência entre prefixo do código IBGE e UF quando ambos conhecidos.
  uf_conhecida_fonte <- tem_muni & uf_fonte != "NI"
  if (any(uf_conhecida_fonte & code_state_fonte != code_state_final)) {
    divergentes <- unique(paste0(
      cod_int[uf_conhecida_fonte & code_state_fonte != code_state_final],
      " (UF fonte=", uf_fonte[uf_conhecida_fonte & code_state_fonte != code_state_final],
      ", geobr=", abbrev_state_final[uf_conhecida_fonte & code_state_fonte != code_state_final], ")"
    ))
    stop(
      "Inconsistência geográfica entre UF da fonte e município no geobr: ",
      paste(utils::head(divergentes, 10), collapse = ", "),
      call. = FALSE
    )
  }

  preparado <- data.frame(
    ano = dados$ano,
    mes = dados$mes,
    code_state = as.integer(code_state_final),
    abbrev_state = as.character(abbrev_state_final),
    code_muni = as.integer(cod_int),
    name_muni = as.character(name_muni_final),
    programa = trimws(as.character(dados$programa)),
    qtd_beneficiarios = para_numerico_seguro(dados$qtd_beneficiarios),
    qtd_parcelas = para_numerico_seguro(dados$qtd_parcelas),
    valor_total = para_numerico_seguro(dados$valor_total),
    stringsAsFactors = FALSE
  )

  # Consolida eventual multiplicidade de sentinelas ausentes (ex.: "" e NA) na mesma chave.
  resultado <- preparado |>
    dplyr::group_by(ano, mes, code_state, abbrev_state, code_muni, name_muni, programa) |>
    dplyr::summarise(
      qtd_beneficiarios = sum(qtd_beneficiarios),
      qtd_parcelas = sum(qtd_parcelas),
      valor_total = sum(valor_total),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      qtd_beneficiarios = converter_inteiro_seguro(qtd_beneficiarios, "qtd_beneficiarios"),
      qtd_parcelas = converter_inteiro_seguro(qtd_parcelas, "qtd_parcelas"),
      valor_total = as.double(valor_total),
      valor_medio = ifelse(qtd_beneficiarios > 0L, valor_total / qtd_beneficiarios, NA_real_)
    ) |>
    dplyr::arrange(ano, mes, code_state, code_muni, programa) |>
    dplyr::select(dplyr::all_of(colunas_saida))

  resultado
}

# 3. VALIDAÇÃO PRÉ-ESCRITA

conferir_calendario_mensal <- function(anos, meses) {
  if (!length(anos) || length(anos) != length(meses) || anyNA(anos) || anyNA(meses) ||
      any(!meses %in% 1:12)) {
    stop("Competências ausentes ou inválidas no calendário mensal.", call. = FALSE)
  }
  competencias <- sort(unique(as.integer(anos) * 100L + as.integer(meses)))
  datas <- as.Date(sprintf("%04d-%02d-01", competencias %/% 100L, competencias %% 100L), format = "%Y-%m-%d")
  if (anyNA(datas)) {
    stop("Competências inválidas no calendário mensal.", call. = FALSE)
  }
  esperado <- seq(min(datas), max(datas), by = "month")
  if (!identical(datas, esperado)) {
    faltantes <- setdiff(format(esperado, "%Y-%m"), format(datas, "%Y-%m"))
    stop(
      "Competências ausentes no calendário mensal: ",
      paste(utils::head(faltantes, 12), collapse = ", "),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

validar_bolsa_familia <- function(
  dados_finais,
  dados_brutos,
  municipios_geobr,
  exigir_27_ufs = TRUE,
  ano_inicial = ano_inicial_padrao
) {
  if (!nrow(dados_finais)) {
    stop("Tabela final está vazia.", call. = FALSE)
  }
  if (!identical(names(dados_finais), colunas_saida)) {
    stop("Esquema de colunas divergente do esperado.", call. = FALSE)
  }

  chave <- dados_finais[c("ano", "mes", "code_state", "code_muni", "programa")]
  if (anyDuplicated(chave)) {
    stop("Existem linhas duplicadas na chave ano x mes x code_state x code_muni x programa.", call. = FALSE)
  }

  obrigatorias <- setdiff(colunas_saida, c("code_muni", "name_muni"))
  if (anyNA(dados_finais[obrigatorias])) {
    stop("Campos obrigatórios ausentes (NA) na tabela final.", call. = FALSE)
  }

  if (any(!dados_finais$programa %in% names(tabelas_pbf))) {
    stop("Valores inválidos na coluna programa.", call. = FALSE)
  }

  if (any(dados_finais$ano < as.integer(ano_inicial))) {
    stop("Registros anteriores ao ano inicial ", ano_inicial, " encontrados na tabela final.", call. = FALSE)
  }

  conferir_calendario_mensal(dados_finais$ano, dados_finais$mes)

  siglas_esperadas <- estados_ibge$abbrev_state[match(dados_finais$code_state, estados_ibge$code_state)]
  if (anyNA(siglas_esperadas) || any(dados_finais$abbrev_state != siglas_esperadas)) {
    stop("Códigos geográficos de UF inconsistentes.", call. = FALSE)
  }

  tem_muni <- !is.na(dados_finais$code_muni)
  if (any(tem_muni & !dados_finais$code_muni %in% municipios_geobr$code_muni) ||
      any(tem_muni & (nchar(dados_finais$code_muni) != 7L |
        dados_finais$code_muni %/% 100000L != dados_finais$code_state)) ||
      any(tem_muni & is.na(dados_finais$name_muni)) ||
      any(!tem_muni & !is.na(dados_finais$name_muni))) {
    stop("Códigos geográficos municipais inconsistentes com geobr.", call. = FALSE)
  }

  if (isTRUE(exigir_27_ufs)) {
    ufs_obrigatorias <- estados_ibge$code_state[estados_ibge$code_state != 99L]
    ausentes_uf <- setdiff(ufs_obrigatorias, unique(dados_finais$code_state))
    if (length(ausentes_uf)) {
      stop("UFs ausentes na tabela final: ", paste(ausentes_uf, collapse = ", "), call. = FALSE)
    }
  }

  if (any(dados_finais$qtd_beneficiarios <= 0L) ||
      any(dados_finais$qtd_parcelas <= 0L) ||
      any(dados_finais$qtd_parcelas < dados_finais$qtd_beneficiarios) ||
      any(!is.finite(dados_finais$valor_total) | dados_finais$valor_total <= 0) ||
      any(!is.finite(dados_finais$valor_medio) | dados_finais$valor_medio <= 0)) {
    stop("Valores negativos, nulos ou não finitos nas métricas financeiras ou de beneficiários.", call. = FALSE)
  }

  # Reconciliação contábil exata dos totais por competência e programa contra os dados brutos.
  esperado <- dados_brutos |>
    dplyr::mutate(
      ano = converter_inteiro_seguro(ano, "ano"),
      mes = converter_inteiro_seguro(mes, "mes"),
      programa = trimws(as.character(programa)),
      qtd_parcelas = para_numerico_seguro(qtd_parcelas),
      valor_total = para_numerico_seguro(valor_total)
    ) |>
    dplyr::filter(ano >= as.integer(ano_inicial)) |>
    dplyr::group_by(ano, mes, programa) |>
    dplyr::summarise(
      qtd_parcelas_fonte = sum(qtd_parcelas),
      valor_total_fonte = sum(valor_total),
      .groups = "drop"
    )

  obtido <- dados_finais |>
    dplyr::group_by(ano, mes, programa) |>
    dplyr::summarise(
      qtd_parcelas_final = sum(as.numeric(qtd_parcelas)),
      valor_total_final = sum(valor_total),
      .groups = "drop"
    )

  comparacao <- dplyr::full_join(esperado, obtido, by = c("ano", "mes", "programa"))
  tolerancia_valor <- 1e-9 * pmax(1, abs(comparacao$valor_total_fonte), abs(comparacao$valor_total_final))

  if (anyNA(comparacao) ||
      any(comparacao$qtd_parcelas_fonte != comparacao$qtd_parcelas_final) ||
      any(abs(comparacao$valor_total_fonte - comparacao$valor_total_final) > tolerancia_valor)) {
    stop("Totais reconciliados por competência/programa divergem da consulta bruta.", call. = FALSE)
  }

  invisible(TRUE)
}

# 4. EXPORTAÇÃO PARQUET E PUBLICAÇÃO NA RELEASE

preparar_asset <- function(dados) {
  arquivo <- file.path(tempdir(), asset_nome)
  arrow::write_parquet(dados, arquivo)
  arquivo
}

publicar_asset <- function(arquivo) {
  if (!nzchar(gh::gh_token())) {
    stop("Autenticação do GitHub ausente. Configure GITHUB_PAT ou gitcreds.", call. = FALSE)
  }
  resposta <- piggyback::pb_upload(
    file = arquivo,
    repo = repo,
    tag = release_tag,
    overwrite = TRUE
  )
  httr::stop_for_status(resposta[[1]])
  invisible(TRUE)
}

fechar_conexoes_arquivo <- function(arquivo) {
  gc()
  conexoes <- showConnections()
  if (nrow(conexoes)) {
    caminhos <- normalizePath(conexoes[, "description"], winslash = "/", mustWork = FALSE)
    destino <- normalizePath(arquivo, winslash = "/", mustWork = FALSE)
    ids <- rownames(conexoes)[conexoes[, "class"] == "file" & caminhos == destino]
    for (id in ids) {
      close(getConnection(as.integer(id)))
    }
  }
  unlink(arquivo)
}

executar <- function(args = commandArgs(trailingOnly = TRUE)) {
  permitidos <- c("--publicar", "--sem-cache")
  if (any(!args %in% permitidos)) {
    stop("Argumento inválido: ", paste(setdiff(args, permitidos), collapse = " "), call. = FALSE)
  }
  if (.Platform$OS.type == "windows") {
    Sys.setlocale("LC_CTYPE", "Portuguese_Brazil.utf8")
  }

  deve_publicar <- "--publicar" %in% args
  usar_cache <- !("--sem-cache" %in% args)

  pacotes <- c("bigrquery", "dplyr", "geobr", "sf", "arrow", "jsonlite")
  if (deve_publicar) {
    pacotes <- c(pacotes, "piggyback", "gh", "httr")
  }
  faltam <- pacotes[!vapply(pacotes, requireNamespace, logical(1), quietly = TRUE)]
  if (length(faltam)) {
    stop("Instale os pacotes necessários: ", paste(faltam, collapse = ", "), call. = FALSE)
  }

  dados_brutos <- baixar_resumo_bigquery(usar_cache = usar_cache)
  municipios_geobr <- obter_referencia_geobr()
  dados_finais <- padronizar_bolsa_familia(dados_brutos, municipios_geobr)
  validar_bolsa_familia(dados_finais, dados_brutos, municipios_geobr)

  arquivo <- preparar_asset(dados_finais)

  if (deve_publicar) {
    on.exit(fechar_conexoes_arquivo(arquivo), add = TRUE)
    publicar_asset(arquivo)
    message("Parquet publicado na release ", release_tag, ": ", asset_nome)
  } else {
    message("Parquet validado em tempdir(): ", normalizePath(arquivo, winslash = "/"))
  }

  invisible(arquivo)
}

if (sys.nframe() == 0L) executar()
