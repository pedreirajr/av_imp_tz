# Pipeline de coleta, tratamento e publicacao do PIB municipal e PIB per capita.
#
# Execute a partir da raiz do projeto:
# source("scripts_dados/pib_municipal_per_capita.R")
# rodar_pipeline_pib_municipal_per_capita(publicar = TRUE)
#
# Fonte oficial:
# https://ftp.ibge.gov.br/Pib_Municipios/2022_2023/base/
#
# Observacoes sobre a fonte e o tratamento:
# - Todas as 43 colunas da planilha sao lidas inicialmente como character.
# - Os identificadores geograficos sao conferidos com o geobr. O nome municipal
#   publicado vem do geobr, conforme o padrao do repositorio.
# - Em 2022 e 2023 o IBGE publicou somente PIB e PIB per capita. Os demais
#   indicadores economicos permanecem NA; ausencia de dado nao e zero.
# - A fonte contem valores negativos validos em algumas contas. Eles sao
#   preservados e auditados, nao substituidos por zero.

URL_BASE_PIB <- "https://ftp.ibge.gov.br/Pib_Municipios/2022_2023/base/"
URL_ARQUIVO_PIB <- paste0(
  URL_BASE_PIB,
  "base_de_dados_2010_2023_xlsx.zip"
)

REPOSITORIO_PIB <- "pedreirajr/av_imp_tz"
TAG_RELEASE_PIB <- "data"
NOME_ASSET_PIB <- "pib_municipal_per_capita.parquet"
NOME_PLANILHA_PIB <- "PIB dos Municípios"
ANO_REFERENCIA_GEOBR_PIB <- 2022L

COLUNAS_FINAIS_PIB <- c(
  "ano",
  "code_muni",
  "name_muni",
  "va_agro",
  "va_ind",
  "va_serv",
  "va_adm",
  "va_total",
  "impostos",
  "pib",
  "pib_pc",
  "ativ_1",
  "ativ_2",
  "ativ_3"
)

dicionario_colunas_pib <- function() {
  tibble::tribble(
    ~nome_original, ~nome_curto, ~tipo, ~unidade,
    "Ano", "ano", "integer", "ano",
    "Código do Município", "code_muni", "integer", "código IBGE de 7 dígitos",
    "Nome do Município", "name_muni", "character", "não se aplica",
    paste0(
      "Valor adicionado bruto da Agropecuária, a preços correntes ",
      "(R$ 1.000)"
    ), "va_agro", "double", "R$ 1.000 correntes",
    paste0(
      "Valor adicionado bruto da Indústria, a preços correntes ",
      "(R$ 1.000)"
    ), "va_ind", "double", "R$ 1.000 correntes",
    paste0(
      "Valor adicionado bruto dos Serviços, a preços correntes - exceto ",
      "Administração, defesa, educação e saúde públicas e seguridade ",
      "social (R$ 1.000)"
    ), "va_serv", "double", "R$ 1.000 correntes",
    paste0(
      "Valor adicionado bruto da Administração, defesa, educação e saúde ",
      "públicas e seguridade social, a preços correntes (R$ 1.000)"
    ), "va_adm", "double", "R$ 1.000 correntes",
    paste0(
      "Valor adicionado bruto total, a preços correntes ",
      "(R$ 1.000)"
    ), "va_total", "double", "R$ 1.000 correntes",
    paste0(
      "Impostos, líquidos de subsídios, sobre produtos, a preços correntes ",
      "(R$ 1.000)"
    ), "impostos", "double", "R$ 1.000 correntes",
    paste0(
      "Produto Interno Bruto, a preços correntes ",
      "(R$ 1.000)"
    ), "pib", "double", "R$ 1.000 correntes",
    paste0(
      "Produto Interno Bruto per capita, a preços correntes ",
      "(R$ 1,00)"
    ), "pib_pc", "double", "R$ correntes por habitante",
    "Atividade com maior valor adicionado bruto",
    "ativ_1", "character", "categoria de atividade econômica",
    "Atividade com segundo maior valor adicionado bruto",
    "ativ_2", "character", "categoria de atividade econômica",
    "Atividade com terceiro maior valor adicionado bruto",
    "ativ_3", "character", "categoria de atividade econômica"
  )
}

categorias_atividade_pib <- function() {
  c(
    "Administração, defesa, educação e saúde públicas e seguridade social",
    "Agricultura, inclusive apoio à agricultura e a pós colheita",
    "Comércio e reparação de veículos automotores e motocicletas",
    "Construção",
    "Demais serviços",
    paste0(
      "Eletricidade e gás, água, esgoto, atividades de gestão de resíduos ",
      "e descontaminação"
    ),
    "Indústrias de transformação",
    "Indústrias extrativas",
    "Pecuária, inclusive apoio à pecuária",
    "Produção florestal, pesca e aquicultura"
  )
}

verificar_pacotes_pib <- function(publicar = FALSE) {
  pacotes <- c(
    "arrow", "dplyr", "geobr", "httr", "janitor", "readr", "readxl",
    "sf", "stringr", "tibble"
  )

  if (publicar) {
    pacotes <- c(pacotes, "piggyback")
  }

  faltando <- pacotes[!vapply(
    pacotes,
    requireNamespace,
    logical(1),
    quietly = TRUE
  )]

  if (length(faltando)) {
    stop(
      "Instale os pacotes necessarios antes de executar o pipeline: ",
      paste(faltando, collapse = ", "),
      call. = FALSE
    )
  }

  invisible(TRUE)
}

normalizar_texto_pib <- function(x) {
  resultado <- x |>
    stringr::str_replace_all("\\u00a0", " ") |>
    stringr::str_squish()

  dplyr::na_if(resultado, "")
}

normalizar_nome_municipio_pib <- function(x) {
  resultado <- x |>
    normalizar_texto_pib() |>
    iconv(from = "UTF-8", to = "ASCII//TRANSLIT") |>
    toupper() |>
    stringr::str_remove_all("[^A-Z0-9]")

  if (any(is.na(resultado) & !is.na(x))) {
    stop("Falha ao normalizar um ou mais nomes geograficos.", call. = FALSE)
  }

  resultado
}

converter_inteiro_pib <- function(x, nome_coluna) {
  texto <- normalizar_texto_pib(x)
  valor <- suppressWarnings(readr::parse_integer(texto, na = character()))
  invalidos <- !is.na(texto) & is.na(valor)

  if (any(invalidos)) {
    amostra <- paste(utils::head(unique(texto[invalidos]), 10L), collapse = ", ")
    stop(
      "Valores inteiros invalidos na coluna ", nome_coluna, ": ", amostra,
      call. = FALSE
    )
  }

  valor
}

converter_double_pib <- function(x, nome_coluna) {
  texto <- normalizar_texto_pib(x)
  valor <- suppressWarnings(readr::parse_double(
    texto,
    na = character(),
    locale = readr::locale(decimal_mark = ".", grouping_mark = ",")
  ))
  invalidos <- !is.na(texto) & is.na(valor)

  if (any(invalidos)) {
    amostra <- paste(utils::head(unique(texto[invalidos]), 10L), collapse = ", ")
    stop(
      "Valores numericos invalidos na coluna ", nome_coluna, ": ", amostra,
      call. = FALSE
    )
  }

  valor
}

baixar_base_pib <- function(dir_raw) {
  dir.create(dir_raw, recursive = TRUE, showWarnings = FALSE)
  caminho_zip <- file.path(dir_raw, basename(URL_ARQUIVO_PIB))

  resposta <- httr::RETRY(
    "GET",
    URL_ARQUIVO_PIB,
    httr::write_disk(caminho_zip, overwrite = TRUE),
    times = 5,
    pause_base = 1,
    terminate_on = c(400L, 401L, 403L, 404L)
  )

  if (httr::status_code(resposta) != 200L) {
    stop(
      "Falha ao baixar a base do IBGE (status ",
      httr::status_code(resposta), ").",
      call. = FALSE
    )
  }

  tamanho <- file.info(caminho_zip)$size
  if (is.na(tamanho) || tamanho < 1e6) {
    stop("O arquivo baixado esta vazio ou incompleto.", call. = FALSE)
  }

  conteudo_zip <- tryCatch(
    utils::unzip(caminho_zip, list = TRUE),
    error = function(erro) {
      stop("O arquivo baixado nao e um ZIP valido: ", erro$message, call. = FALSE)
    }
  )

  arquivos_xlsx <- conteudo_zip$Name[
    stringr::str_detect(conteudo_zip$Name, stringr::regex("\\.xlsx$", TRUE))
  ]

  if (length(arquivos_xlsx) != 1L) {
    stop(
      "O ZIP do IBGE deve conter exatamente um arquivo .xlsx; encontrados: ",
      length(arquivos_xlsx),
      call. = FALSE
    )
  }

  caminho_xlsx <- file.path(dir_raw, "pib_municipal_2010_2023_raw.xlsx")
  conexao_origem <- unz(caminho_zip, arquivos_xlsx, open = "rb")
  conexao_destino <- file(caminho_xlsx, open = "wb")
  on.exit({
    try(close(conexao_origem), silent = TRUE)
    try(close(conexao_destino), silent = TRUE)
  }, add = TRUE)

  repeat {
    bloco <- readBin(conexao_origem, what = "raw", n = 1024L * 1024L)
    if (!length(bloco)) break
    writeBin(bloco, conexao_destino)
  }
  close(conexao_origem)
  close(conexao_destino)

  tamanho_xlsx <- file.info(caminho_xlsx)$size
  if (is.na(tamanho_xlsx) || tamanho_xlsx < 1e6) {
    stop("Nao foi possivel extrair a planilha do ZIP do IBGE.", call. = FALSE)
  }

  message("Planilha oficial baixada e extraida: ", basename(caminho_xlsx))
  caminho_xlsx
}

ler_base_pib <- function(caminho_xlsx) {
  planilhas <- readxl::excel_sheets(caminho_xlsx)
  indice_planilha <- which(vapply(
    planilhas,
    function(nome) identical(charToRaw(nome), charToRaw(NOME_PLANILHA_PIB)),
    logical(1)
  ))

  if (length(indice_planilha) != 1L) {
    stop(
      "A planilha esperada nao existe no arquivo: ", NOME_PLANILHA_PIB,
      call. = FALSE
    )
  }

  dados <- readxl::read_excel(
    caminho_xlsx,
    sheet = planilhas[indice_planilha],
    col_types = "text",
    na = "",
    trim_ws = FALSE,
    .name_repair = "minimal"
  )

  if (!nrow(dados)) {
    stop("A planilha do IBGE foi lida sem registros.", call. = FALSE)
  }

  if (!all(vapply(dados, is.character, logical(1)))) {
    stop(
      "Contrato de leitura violado: todas as colunas devem entrar como character.",
      call. = FALSE
    )
  }

  nomes_normalizados <- normalizar_texto_pib(names(dados))
  if (anyNA(nomes_normalizados) || anyDuplicated(nomes_normalizados)) {
    stop("Ha cabecalhos vazios ou repetidos na planilha do IBGE.", call. = FALSE)
  }
  names(dados) <- nomes_normalizados

  dicionario <- dicionario_colunas_pib()
  dados <- janitor::clean_names(dados)
  nomes_limpos_dicionario <- janitor::make_clean_names(dicionario$nome_original)
  faltantes <- setdiff(nomes_limpos_dicionario, names(dados))

  if (length(faltantes)) {
    stop(
      "Colunas finais ausentes depois de janitor::clean_names(): ",
      paste(faltantes, collapse = "; "),
      call. = FALSE
    )
  }

  indices <- match(nomes_limpos_dicionario, names(dados))

  if (anyNA(indices)) {
    stop("Falha ao localizar colunas depois de janitor::clean_names().", call. = FALSE)
  }

  names(dados)[indices] <- dicionario$nome_curto
  dados
}

tipar_base_pib <- function(dados) {
  colunas_auxiliares <- c(
    "codigo_da_grande_regiao",
    "nome_da_grande_regiao",
    "codigo_da_unidade_da_federacao",
    "sigla_da_unidade_da_federacao",
    "nome_da_unidade_da_federacao"
  )
  faltantes <- setdiff(c(colunas_auxiliares, COLUNAS_FINAIS_PIB), names(dados))

  if (length(faltantes)) {
    stop(
      "Colunas necessarias para tipagem e validacao espacial ausentes: ",
      paste(faltantes, collapse = ", "),
      call. = FALSE
    )
  }

  dados |>
    dplyr::transmute(
      ano = converter_inteiro_pib(.data$ano, "ano"),
      code_muni_origem = converter_inteiro_pib(.data$code_muni, "code_muni"),
      name_muni_origem = normalizar_texto_pib(.data$name_muni),
      code_state_origem = converter_inteiro_pib(
        .data$codigo_da_unidade_da_federacao,
        "codigo_da_unidade_da_federacao"
      ),
      abbrev_state_origem = normalizar_texto_pib(
        .data$sigla_da_unidade_da_federacao
      ),
      name_state_origem = normalizar_texto_pib(
        .data$nome_da_unidade_da_federacao
      ),
      code_region_origem = converter_inteiro_pib(
        .data$codigo_da_grande_regiao,
        "codigo_da_grande_regiao"
      ),
      name_region_origem = normalizar_texto_pib(.data$nome_da_grande_regiao),
      va_agro = converter_double_pib(.data$va_agro, "va_agro"),
      va_ind = converter_double_pib(.data$va_ind, "va_ind"),
      va_serv = converter_double_pib(.data$va_serv, "va_serv"),
      va_adm = converter_double_pib(.data$va_adm, "va_adm"),
      va_total = converter_double_pib(.data$va_total, "va_total"),
      impostos = converter_double_pib(.data$impostos, "impostos"),
      pib = converter_double_pib(.data$pib, "pib"),
      pib_pc = converter_double_pib(.data$pib_pc, "pib_pc"),
      ativ_1 = normalizar_texto_pib(.data$ativ_1),
      ativ_2 = normalizar_texto_pib(.data$ativ_2),
      ativ_3 = normalizar_texto_pib(.data$ativ_3)
    )
}

obter_referencia_municipios_pib <- function() {
  referencia <- geobr::read_municipality(
    year = ANO_REFERENCIA_GEOBR_PIB,
    simplified = TRUE,
    showProgress = FALSE,
    cache = TRUE,
    verbose = FALSE
  ) |>
    sf::st_drop_geometry()

  if (is.null(referencia) || !nrow(referencia)) {
    stop("Nao foi possivel obter a referencia municipal do geobr.", call. = FALSE)
  }

  referencia <- referencia |>
    dplyr::transmute(
      code_muni = as.integer(code_muni),
      name_muni,
      code_state = as.integer(code_state),
      abbrev_state,
      name_state,
      code_region = as.integer(code_region),
      name_region,
      nome_muni_norm = normalizar_nome_municipio_pib(name_muni),
      nome_state_norm = normalizar_nome_municipio_pib(name_state),
      nome_region_norm = normalizar_nome_municipio_pib(name_region)
    )

  if (anyDuplicated(referencia$code_muni)) {
    stop("A referencia do geobr possui code_muni duplicado.", call. = FALSE)
  }

  if (anyDuplicated(referencia[c("abbrev_state", "nome_muni_norm")])) {
    stop(
      "A referencia do geobr possui nome municipal normalizado duplicado na UF.",
      call. = FALSE
    )
  }

  referencia
}

reconciliar_municipios_pib <- function(dados, referencia) {
  referencia_codigo <- referencia |>
    dplyr::transmute(
      code_muni_origem = code_muni,
      code_muni_codigo = code_muni,
      name_muni_codigo = name_muni,
      code_state_codigo = code_state,
      abbrev_state_codigo = abbrev_state,
      name_state_norm_codigo = nome_state_norm,
      code_region_codigo = code_region,
      name_region_norm_codigo = nome_region_norm,
      nome_muni_norm_codigo = nome_muni_norm
    )

  referencia_nome <- referencia |>
    dplyr::transmute(
      nome_muni_norm_origem = nome_muni_norm,
      abbrev_state_origem = abbrev_state,
      code_muni_nome = code_muni,
      name_muni_nome = name_muni,
      code_state_nome = code_state,
      code_region_nome = code_region,
      name_state_norm_nome = nome_state_norm,
      name_region_norm_nome = nome_region_norm
    )

  dados_conferidos <- dados |>
    dplyr::mutate(
      nome_muni_norm_origem = normalizar_nome_municipio_pib(name_muni_origem),
      nome_state_norm_origem = normalizar_nome_municipio_pib(name_state_origem),
      nome_region_norm_origem = normalizar_nome_municipio_pib(name_region_origem)
    ) |>
    dplyr::left_join(referencia_codigo, by = "code_muni_origem") |>
    dplyr::left_join(
      referencia_nome,
      by = c("nome_muni_norm_origem", "abbrev_state_origem")
    ) |>
    dplyr::mutate(
      codigo_auxiliares_conferem = !is.na(code_muni_codigo) &
        code_state_origem == code_state_codigo &
        abbrev_state_origem == abbrev_state_codigo &
        nome_state_norm_origem == name_state_norm_codigo &
        code_region_origem == code_region_codigo &
        nome_region_norm_origem == name_region_norm_codigo,
      codigo_e_nome_conferem = codigo_auxiliares_conferem &
        nome_muni_norm_origem == nome_muni_norm_codigo,
      nome_auxiliares_conferem = !is.na(code_muni_nome) &
        code_state_origem == code_state_nome &
        nome_state_norm_origem == name_state_norm_nome &
        code_region_origem == code_region_nome &
        nome_region_norm_origem == name_region_norm_nome,
      metodo_reconciliacao = dplyr::case_when(
        codigo_e_nome_conferem ~ "codigo_nome_e_auxiliares",
        nome_auxiliares_conferem ~ "nome_e_uf",
        codigo_auxiliares_conferem ~ "codigo_e_auxiliares",
        TRUE ~ NA_character_
      ),
      code_muni = dplyr::case_when(
        metodo_reconciliacao == "nome_e_uf" ~ code_muni_nome,
        !is.na(metodo_reconciliacao) ~ code_muni_codigo,
        TRUE ~ NA_integer_
      ),
      name_muni = dplyr::case_when(
        metodo_reconciliacao == "nome_e_uf" ~ name_muni_nome,
        !is.na(metodo_reconciliacao) ~ name_muni_codigo,
        TRUE ~ NA_character_
      )
    )

  divergencias <- dados_conferidos |>
    dplyr::filter(is.na(metodo_reconciliacao)) |>
    dplyr::distinct(
      ano,
      code_muni_origem,
      name_muni_origem,
      code_state_origem,
      abbrev_state_origem
    )

  if (nrow(divergencias)) {
    amostra <- paste(
      capture.output(print(utils::head(divergencias, 20L), n = 20L)),
      collapse = "\n"
    )
    stop(
      "Persistem divergencias espaciais nao resolvidas com o geobr:\n",
      amostra,
      call. = FALSE
    )
  }

  correcoes <- dados_conferidos |>
    dplyr::filter(
      code_muni != code_muni_origem |
        normalizar_nome_municipio_pib(name_muni) != nome_muni_norm_origem
    ) |>
    dplyr::transmute(
      ano,
      code_muni_origem,
      name_muni_origem,
      code_muni,
      name_muni,
      metodo_reconciliacao,
      tipo_correcao = dplyr::case_when(
        code_muni != code_muni_origem ~ "codigo_e_nome",
        TRUE ~ "nome"
      )
    )

  if (nrow(correcoes)) {
    message(
      "Registros municipio/ano corrigidos com o geobr: ", nrow(correcoes),
      " (", dplyr::n_distinct(correcoes$code_muni), " municipios)."
    )
  }

  dados_finais <- dados_conferidos |>
    dplyr::transmute(
      ano = as.integer(ano),
      code_muni = as.integer(code_muni),
      name_muni,
      va_agro,
      va_ind,
      va_serv,
      va_adm,
      va_total,
      impostos,
      pib,
      pib_pc,
      ativ_1,
      ativ_2,
      ativ_3
    ) |>
    dplyr::arrange(ano, code_muni)

  list(dados = dados_finais, correcoes = correcoes)
}

validar_base_pib <- function(dados, referencia) {
  if (!identical(names(dados), COLUNAS_FINAIS_PIB)) {
    stop(
      "O esquema final difere do contrato: ",
      paste(names(dados), collapse = ", "),
      call. = FALSE
    )
  }

  if (!nrow(dados)) {
    stop("O dataframe final esta vazio.", call. = FALSE)
  }

  if (!is.integer(dados$ano) || !is.integer(dados$code_muni)) {
    stop("ano e code_muni devem ser integer.", call. = FALSE)
  }

  colunas_double <- c(
    "va_agro", "va_ind", "va_serv", "va_adm", "va_total", "impostos",
    "pib", "pib_pc"
  )
  if (!all(vapply(dados[colunas_double], is.double, logical(1)))) {
    stop("Todas as medidas economicas devem ser double.", call. = FALSE)
  }

  if (anyNA(dados[c("ano", "code_muni", "name_muni")])) {
    stop("Ha identificadores municipais ausentes.", call. = FALSE)
  }

  codigos_invalidos <- !stringr::str_detect(
    as.character(dados$code_muni),
    "^[1-5][0-9]{6}$"
  )
  if (any(codigos_invalidos)) {
    stop("Ha code_muni fora do padrao IBGE de sete digitos.", call. = FALSE)
  }

  if (anyDuplicated(dados[c("ano", "code_muni")])) {
    stop("Ha duplicidade na chave ano x code_muni.", call. = FALSE)
  }

  if (anyDuplicated(dados)) {
    stop("Ha linhas integralmente duplicadas no resultado.", call. = FALSE)
  }

  codigos_fora_geobr <- setdiff(
    unique(dados$code_muni),
    unique(referencia$code_muni)
  )
  if (length(codigos_fora_geobr)) {
    stop(
      "Ha codigos municipais ausentes no geobr: ",
      paste(codigos_fora_geobr, collapse = ", "),
      call. = FALSE
    )
  }

  cobertura_observada <- dados |>
    dplyr::count(ano, name = "municipios") |>
    dplyr::arrange(ano)
  cobertura_esperada <- tibble::tibble(
    ano = 2010:2023,
    municipios = c(rep(5565L, 3L), rep(5570L, 11L))
  )

  if (!identical(cobertura_observada, cobertura_esperada)) {
    stop(
      "A cobertura anual nao corresponde aos 5.565 municipios em 2010-2012 ",
      "e 5.570 municipios em 2013-2023.",
      call. = FALSE
    )
  }

  valores_numericos <- unlist(dados[colunas_double], use.names = FALSE)
  valores_presentes <- valores_numericos[!is.na(valores_numericos)]
  if (any(!is.finite(valores_presentes))) {
    stop("Ha valor economico nao finito no resultado.", call. = FALSE)
  }

  historico <- dplyr::filter(dados, ano <= 2021L)
  colunas_completas_historico <- c(
    colunas_double, "ativ_1", "ativ_2", "ativ_3"
  )
  if (anyNA(historico[colunas_completas_historico])) {
    stop("Ha valores ausentes inesperados entre 2010 e 2021.", call. = FALSE)
  }

  anos_recentes <- dplyr::filter(dados, ano %in% c(2022L, 2023L))
  colunas_ausentes_esperadas <- c(
    "va_agro", "va_ind", "va_serv", "va_adm", "va_total", "impostos",
    "ativ_1", "ativ_2", "ativ_3"
  )

  if (any(!is.na(unlist(
    anos_recentes[colunas_ausentes_esperadas],
    use.names = FALSE
  )))) {
    stop(
      "2022 e 2023 devem conter NA nas contas e atividades nao divulgadas.",
      call. = FALSE
    )
  }

  if (anyNA(anos_recentes[c("pib", "pib_pc")])) {
    stop("PIB e PIB per capita devem estar preenchidos em 2022 e 2023.", call. = FALSE)
  }

  diferenca_va <- abs(
    historico$va_agro + historico$va_ind + historico$va_serv +
      historico$va_adm - historico$va_total
  )
  if (any(diferenca_va > 0.01)) {
    stop("va_total nao fecha com seus quatro componentes.", call. = FALSE)
  }

  diferenca_pib <- abs(historico$va_total + historico$impostos - historico$pib)
  if (any(diferenca_pib > 0.01)) {
    stop("pib nao fecha com va_total mais impostos.", call. = FALSE)
  }

  atividades_presentes <- unique(unlist(
    dados[c("ativ_1", "ativ_2", "ativ_3")],
    use.names = FALSE
  ))
  atividades_presentes <- atividades_presentes[!is.na(atividades_presentes)]
  atividades_norm <- normalizar_nome_municipio_pib(atividades_presentes)
  categorias_norm <- normalizar_nome_municipio_pib(categorias_atividade_pib())
  atividades_invalidas <- atividades_presentes[
    !atividades_norm %in% categorias_norm
  ]
  if (length(atividades_invalidas)) {
    stop(
      "Categorias de atividade economica nao reconhecidas: ",
      paste(atividades_invalidas, collapse = "; "),
      call. = FALSE
    )
  }

  negativos <- sum(valores_presentes < 0)
  if (negativos) {
    message(
      "Valores negativos preservados por constarem na fonte oficial: ",
      negativos, "."
    )
  }

  invisible(cobertura_observada)
}

gravar_parquet_pib <- function(dados, caminho_parquet) {
  dir.create(dirname(caminho_parquet), recursive = TRUE, showWarnings = FALSE)
  arrow::write_parquet(dados, caminho_parquet, compression = "snappy")

  dados_lidos <- arrow::read_parquet(caminho_parquet, as_data_frame = TRUE)
  comparacao <- all.equal(
    as.data.frame(dados_lidos),
    as.data.frame(dados),
    check.attributes = FALSE,
    tolerance = 1e-10
  )

  if (!isTRUE(comparacao)) {
    stop(
      "A verificacao de leitura do Parquet falhou: ",
      paste(comparacao, collapse = "; "),
      call. = FALSE
    )
  }

  message("Parquet gerado e relido com sucesso: ", basename(caminho_parquet))
  caminho_parquet
}

publicar_parquet_pib <- function(caminho_parquet) {
  if (!nzchar(Sys.getenv("GITHUB_PAT"))) {
    stop(
      "GITHUB_PAT nao esta configurado. Configure o token apenas na sessao R ",
      "antes de publicar.",
      call. = FALSE
    )
  }

  piggyback::pb_upload(
    file = caminho_parquet,
    repo = REPOSITORIO_PIB,
    tag = TAG_RELEASE_PIB,
    overwrite = TRUE,
    show_progress = TRUE
  )

  message(
    "Publicacao concluida na release '", TAG_RELEASE_PIB,
    "' de ", REPOSITORIO_PIB, "."
  )
}

rodar_pipeline_pib_municipal_per_capita <- function(publicar = TRUE) {
  verificar_pacotes_pib(publicar = publicar)

  diretorio_trabalho <- tempfile("pib_municipal_per_capita_")
  dir_raw <- file.path(diretorio_trabalho, "raw")
  dir_parquet <- file.path(diretorio_trabalho, "parquet")
  dir.create(diretorio_trabalho, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(diretorio_trabalho, recursive = TRUE, force = TRUE), add = TRUE)

  caminho_xlsx <- baixar_base_pib(dir_raw)
  dados_brutos <- ler_base_pib(caminho_xlsx)
  dados_tipados <- tipar_base_pib(dados_brutos)
  referencia <- obter_referencia_municipios_pib()
  resultado_municipios <- reconciliar_municipios_pib(dados_tipados, referencia)
  dados <- resultado_municipios$dados

  cobertura <- validar_base_pib(dados, referencia)
  caminho_parquet <- file.path(dir_parquet, NOME_ASSET_PIB)
  gravar_parquet_pib(dados, caminho_parquet)

  if (publicar) {
    publicar_parquet_pib(caminho_parquet)
  } else {
    message("Publicacao desativada; os arquivos temporarios serao removidos.")
  }

  colunas_double <- c(
    "va_agro", "va_ind", "va_serv", "va_adm", "va_total", "impostos",
    "pib", "pib_pc"
  )
  negativos <- sum(unlist(dados[colunas_double], use.names = FALSE) < 0, na.rm = TRUE)
  ausencias_metodologicas <- sum(is.na(dados))

  resumo <- tibble::tibble(
    arquivo = NOME_ASSET_PIB,
    linhas = nrow(dados),
    ano_inicial = min(dados$ano),
    ano_final = max(dados$ano),
    municipios_distintos = dplyr::n_distinct(dados$code_muni),
    municipios_corrigidos = dplyr::n_distinct(
      resultado_municipios$correcoes$code_muni
    ),
    registros_corrigidos = nrow(resultado_municipios$correcoes),
    valores_negativos = negativos,
    ausencias_metodologicas = ausencias_metodologicas,
    publicado = publicar
  )

  print(resumo)
  print(cobertura)
  invisible(resumo)
}
