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

# 2. REFERÊNCIA GEOGRÁFICA (GEOBR) E PADRONIZAÇÃO MUNICIPAL

obter_referencia_geobr <- function() {
  message("Carregando tabela de referência municipal do geobr (2022)...")
  # read_municipality(2022) traz Fernando de Noronha (2605459), ausente em lookup_muni(2022);
  # lookup_muni(2022) traz Boa Esperança do Norte (5101837), ausente em read_municipality(2022).
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

codigo_municipio_nao_identificado <- function(x, code_state_fonte = NULL) {
  limpo <- trimws(as.character(x))
  sentinela <- is.na(limpo) |
    limpo %in% c("", "0", "00", "000000", "0000000", "99", "999999", "9999999") |
    grepl("^\\{", limpo)
  if (is.null(code_state_fonte)) {
    return(sentinela)
  }
  ufs_validas <- estados_ibge$code_state[estados_ibge$code_state != 99L]
  ignorado_uf <- !is.na(limpo) &
    code_state_fonte %in% ufs_validas &
    limpo == paste0(code_state_fonte, "9999")
  sentinela | ignorado_uf
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

filtrar_escopo_rais <- function(dados, ano_inicial = ano_inicial_padrao) {
  ano_num <- converter_inteiro_seguro(dados$ano, "ano")
  dados[ano_num >= as.integer(ano_inicial), , drop = FALSE]
}

normalizar_uf_fonte <- function(sigla_uf) {
  uf <- toupper(trimws(as.character(sigla_uf)))
  ufs_validas <- estados_ibge$abbrev_state[estados_ibge$code_state != 99L]
  uf[is.na(uf) | !uf %in% ufs_validas] <- "NI"
  uf
}

padronizar_rais_estoque <- function(
  dados_brutos,
  municipios_geobr,
  ano_inicial = ano_inicial_padrao
) {
  esperadas <- c("ano", "sigla_uf_fonte", "id_municipio_fonte", "vinculos_ativos")
  faltando <- setdiff(esperadas, names(dados_brutos))
  if (length(faltando)) {
    stop("Colunas obrigatórias ausentes na consulta bruta: ", paste(faltando, collapse = ", "), call. = FALSE)
  }

  dados <- as.data.frame(dados_brutos, stringsAsFactors = FALSE)
  dados <- filtrar_escopo_rais(dados, ano_inicial = ano_inicial)
  dados$ano <- converter_inteiro_seguro(dados$ano, "ano")

  if (!nrow(dados)) {
    stop("Consulta bruta não retornou registros no período >= ", ano_inicial, ".", call. = FALSE)
  }

  uf_fonte <- normalizar_uf_fonte(dados$sigla_uf_fonte)
  code_state_fonte <- estados_ibge$code_state[match(uf_fonte, estados_ibge$abbrev_state)]

  cod_txt <- trimws(as.character(dados$id_municipio_fonte))
  ausente <- codigo_municipio_nao_identificado(cod_txt, code_state_fonte)
  cod_txt[ausente] <- NA_character_

  nao_ausente <- !is.na(cod_txt)
  if (any(nao_ausente & !grepl("^[0-9]{6,7}$", cod_txt))) {
    invalidos <- unique(cod_txt[nao_ausente & !grepl("^[0-9]{6,7}$", cod_txt)])
    stop(
      "Código de município com formato inválido (esperado 6 ou 7 dígitos IBGE): ",
      paste(utils::head(invalidos, 10), collapse = ", "),
      call. = FALSE
    )
  }

  seis_digitos_geobr <- municipios_geobr$code_muni %/% 10L
  if (anyDuplicated(seis_digitos_geobr)) {
    stop("Tabela de referência geobr ambígua em 6 dígitos.", call. = FALSE)
  }

  cod_num <- suppressWarnings(as.integer(cod_txt))
  idx_geo <- rep(NA_integer_, length(cod_num))
  eh_7 <- nao_ausente & nchar(cod_txt) == 7L
  eh_6 <- nao_ausente & nchar(cod_txt) == 6L
  idx_geo[eh_7] <- match(cod_num[eh_7], municipios_geobr$code_muni)
  idx_geo[eh_6] <- match(cod_num[eh_6], seis_digitos_geobr)

  if (any(nao_ausente & is.na(idx_geo))) {
    inexistentes <- unique(cod_txt[nao_ausente & is.na(idx_geo)])
    stop(
      "Município ausente no geobr (2022): ",
      paste(utils::head(inexistentes, 10), collapse = ", "),
      call. = FALSE
    )
  }

  tem_muni <- !is.na(idx_geo)
  code_muni_final <- ifelse(tem_muni, municipios_geobr$code_muni[idx_geo], NA_integer_)
  code_state_final <- ifelse(tem_muni, municipios_geobr$code_state[idx_geo], code_state_fonte)
  abbrev_state_final <- ifelse(tem_muni, municipios_geobr$abbrev_state[idx_geo], uf_fonte)
  name_muni_final <- ifelse(tem_muni, municipios_geobr$name_muni[idx_geo], NA_character_)

  uf_conhecida_fonte <- tem_muni & uf_fonte != "NI"
  if (any(uf_conhecida_fonte & code_state_fonte != code_state_final)) {
    divergentes <- unique(paste0(
      code_muni_final[uf_conhecida_fonte & code_state_fonte != code_state_final],
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
    code_state = as.integer(code_state_final),
    abbrev_state = as.character(abbrev_state_final),
    code_muni = as.integer(code_muni_final),
    name_muni = as.character(name_muni_final),
    vinculos_ativos = para_numerico_seguro(dados$vinculos_ativos),
    stringsAsFactors = FALSE
  )

  # Consolida eventual multiplicidade de sentinelas ausentes (ex.: "" e NA) na mesma chave.
  preparado |>
    dplyr::group_by(ano, code_state, abbrev_state, code_muni, name_muni) |>
    dplyr::summarise(
      vinculos_ativos = sum(vinculos_ativos),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      vinculos_ativos = converter_inteiro_seguro(vinculos_ativos, "vinculos_ativos")
    ) |>
    dplyr::arrange(ano, code_state, code_muni) |>
    dplyr::select(dplyr::all_of(colunas_saida))
}

# 3. VALIDAÇÃO PRÉ-ESCRITA

conferir_calendario_anual <- function(anos) {
  if (!length(anos) || anyNA(anos) || any(anos != floor(anos))) {
    stop("Anos ausentes ou inválidos no calendário anual.", call. = FALSE)
  }
  unicos <- sort(unique(as.integer(anos)))
  esperado <- seq.int(min(unicos), max(unicos))
  if (!identical(unicos, esperado)) {
    faltantes <- setdiff(esperado, unicos)
    stop(
      "Anos ausentes no calendário anual: ",
      paste(utils::head(faltantes, 12), collapse = ", "),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

validar_rais_estoque <- function(
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

  chave <- dados_finais[c("ano", "code_state", "code_muni")]
  if (anyDuplicated(chave)) {
    stop("Existem linhas duplicadas na chave ano x code_state x code_muni.", call. = FALSE)
  }

  obrigatorias <- setdiff(colunas_saida, c("code_muni", "name_muni"))
  if (anyNA(dados_finais[obrigatorias])) {
    stop("Campos obrigatórios ausentes (NA) na tabela final.", call. = FALSE)
  }

  if (any(dados_finais$ano < as.integer(ano_inicial))) {
    stop("Registros anteriores ao ano inicial ", ano_inicial, " encontrados na tabela final.", call. = FALSE)
  }

  conferir_calendario_anual(dados_finais$ano)

  siglas_esperadas <- estados_ibge$abbrev_state[match(dados_finais$code_state, estados_ibge$code_state)]
  if (anyNA(siglas_esperadas) || any(dados_finais$abbrev_state != siglas_esperadas)) {
    stop("Códigos geográficos de UF inconsistentes.", call. = FALSE)
  }

  tem_muni <- !is.na(dados_finais$code_muni)
  idx_geo <- match(dados_finais$code_muni[tem_muni], municipios_geobr$code_muni)
  if (anyNA(idx_geo) ||
      any(nchar(dados_finais$code_muni[tem_muni]) != 7L) ||
      any(dados_finais$code_muni[tem_muni] %/% 100000L != dados_finais$code_state[tem_muni]) ||
      any(is.na(dados_finais$name_muni[tem_muni])) ||
      any(dados_finais$name_muni[tem_muni] != municipios_geobr$name_muni[idx_geo]) ||
      any(!tem_muni & !is.na(dados_finais$name_muni))) {
    stop("Códigos geográficos municipais inconsistentes com geobr.", call. = FALSE)
  }

  if (isTRUE(exigir_27_ufs)) {
    ufs_obrigatorias <- estados_ibge$code_state[estados_ibge$code_state != 99L]
    for (ano_ref in sort(unique(dados_finais$ano))) {
      ufs_ano <- unique(dados_finais$code_state[dados_finais$ano == ano_ref])
      ausentes_uf <- setdiff(ufs_obrigatorias, ufs_ano)
      if (length(ausentes_uf)) {
        stop(
          "UFs ausentes em ", ano_ref, ": ", paste(ausentes_uf, collapse = ", "),
          call. = FALSE
        )
      }
    }
  }

  if (!is.integer(dados_finais$vinculos_ativos) ||
      any(!is.finite(dados_finais$vinculos_ativos) | dados_finais$vinculos_ativos < 0L)) {
    stop("Valores negativos ou inválidos em vinculos_ativos.", call. = FALSE)
  }

  # Reconciliação contábil exata dos totais por ano e UF contra a consulta bruta filtrada.
  brutos_filt <- filtrar_escopo_rais(as.data.frame(dados_brutos, stringsAsFactors = FALSE), ano_inicial = ano_inicial)
  uf_bruta <- normalizar_uf_fonte(brutos_filt$sigla_uf_fonte)
  code_state_bruto <- estados_ibge$code_state[match(uf_bruta, estados_ibge$abbrev_state)]
  cod_bruto <- trimws(as.character(brutos_filt$id_municipio_fonte))
  muni_valido_bruto <- !codigo_municipio_nao_identificado(cod_bruto, code_state_bruto) &
    grepl("^[0-9]{6,7}$", cod_bruto)
  sem_uf_com_muni <- code_state_bruto == 99L & muni_valido_bruto
  code_state_bruto[sem_uf_com_muni] <- as.integer(substr(cod_bruto[sem_uf_com_muni], 1L, 2L))

  esperado <- data.frame(
    ano = converter_inteiro_seguro(brutos_filt$ano, "ano"),
    code_state = as.integer(code_state_bruto),
    vinculos_ativos = para_numerico_seguro(brutos_filt$vinculos_ativos),
    stringsAsFactors = FALSE
  ) |>
    dplyr::group_by(ano, code_state) |>
    dplyr::summarise(vinculos_fonte = sum(vinculos_ativos), .groups = "drop")

  obtido <- dados_finais |>
    dplyr::group_by(ano, code_state) |>
    dplyr::summarise(vinculos_final = sum(as.numeric(vinculos_ativos)), .groups = "drop")

  comparacao <- dplyr::full_join(esperado, obtido, by = c("ano", "code_state"))
  if (anyNA(comparacao) || any(comparacao$vinculos_fonte != comparacao$vinculos_final)) {
    stop("Totais reconciliados por ano/UF divergem da consulta bruta.", call. = FALSE)
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
  permitidos <- c("--publicar", "--usar-cache")
  if (any(!args %in% permitidos)) {
    stop("Argumento inválido: ", paste(setdiff(args, permitidos), collapse = " "), call. = FALSE)
  }
  if (.Platform$OS.type == "windows") {
    Sys.setlocale("LC_CTYPE", "Portuguese_Brazil.utf8")
  }

  deve_publicar <- "--publicar" %in% args
  usar_cache <- "--usar-cache" %in% args

  pacotes <- c("bigrquery", "dplyr", "geobr", "sf", "arrow", "jsonlite")
  if (deve_publicar) {
    pacotes <- c(pacotes, "piggyback", "gh", "httr")
  }
  faltam <- pacotes[!vapply(pacotes, requireNamespace, logical(1), quietly = TRUE)]
  if (length(faltam)) {
    stop("Instale os pacotes necessários: ", paste(faltam, collapse = ", "), call. = FALSE)
  }

  dados_brutos <- baixar_resumo_rais_bigquery(usar_cache = usar_cache)
  municipios_geobr <- obter_referencia_geobr()
  dados_finais <- padronizar_rais_estoque(dados_brutos, municipios_geobr)
  validar_rais_estoque(dados_finais, dados_brutos, municipios_geobr)

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
