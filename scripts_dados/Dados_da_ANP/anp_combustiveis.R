# Pipeline de coleta, tratamento e publicacao dos dados municipais da ANP.
#
# Execute a partir da raiz do projeto:
# source("scripts_dados/Dados_da_ANP/anp_combustiveis.R", encoding = "UTF-8")
# rodar_pipeline_anp(publicar = TRUE)

URL_ANP <- paste0(
  "https://www.gov.br/anp/pt-br/centrais-de-conteudo/dados-abertos/",
  "vendas-de-derivados-de-petroleo-e-biocombustiveis"
)

REPOSITORIO_ANP <- "pedreirajr/av_imp_tz"
TAG_RELEASE_ANP <- "data"

configuracao_arquivos_anp <- function() {
  tibble::tribble(
    ~nome_origem, ~tipo,
    "vendas-anuais-de-etanol-hidratado-por-municipio.csv", "padrao",
    "vendas-anuais-de-gasolina-c-por-municipio.csv", "padrao",
    "vendas-anuais-de-glp-por-municipio.csv", "glp",
    "vendas-anuais-de-oleo-diesel-por-municipio.csv", "padrao"
  ) |>
    dplyr::mutate(
      nome_raw = stringr::str_replace(nome_origem, "\\.csv$", "-raw.csv"),
      nome_parquet = stringr::str_replace(nome_origem, "\\.csv$", ".parquet")
    )
}

verificar_pacotes_anp <- function(publicar = FALSE) {
  pacotes <- c(
    "arrow", "dplyr", "geobr", "httr", "purrr", "readr", "rvest",
    "stringr", "tibble", "tidyr", "xml2"
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

normalizar_nome_municipio <- function(x) {
  resultado <- x |>
    stringr::str_squish() |>
    iconv(from = "UTF-8", to = "ASCII//TRANSLIT") |>
    toupper() |>
    stringr::str_remove_all("[^A-Z0-9]")

  if (any(is.na(resultado) & !is.na(x))) {
    stop("Falha ao normalizar um ou mais nomes de municipio.", call. = FALSE)
  }

  resultado
}

renomeacoes_conferidas_anp <- function() {
  renomeacoes <- tibble::tribble(
    ~abbrev_state_anp, ~name_muni_anp, ~name_muni_geobr, ~motivo,
    "AC", "SANTA ROSA", "SANTA ROSA DO PURUS", "nome historico",
    "BA", "JEQUIRICA", "JIQUIRICA", "grafia conferida",
    "BA", "MUQUEM DE SAO FRANCISCO", "MUQUEM DO SAO FRANCISCO", "grafia conferida",
    "BA", "SANTA TERESINHA", "SANTA TEREZINHA", "grafia conferida",
    "GO", "BOM JESUS DE GOIAS", "BOM JESUS", "nome oficial atual",
    "GO", "PLANALTINA DE GOIAS", "PLANALTINA", "nome oficial atual",
    "MA", "BURITIRAMA", "BURITIRANA", "grafia conferida",
    "MA", "GOVERNADOR EDSON LOBAO", "GOVERNADOR EDISON LOBAO", "grafia conferida",
    "MA", "SANTO AMARO", "SANTO AMARO DO MARANHAO", "nome oficial atual",
    "MA", "SENADOR LA ROQUE", "SENADOR LA ROCQUE", "grafia conferida",
    "MG", "AMPARO DA SERRA", "AMPARO DO SERRA", "nome oficial atual",
    "MG", "BARAO DE MONTE ALTO", "BARAO DO MONTE ALTO", "grafia conferida",
    "MG", "BRASOPOLIS", "BRAZOPOLIS", "grafia conferida",
    "MG", "GOUVEA", "GOUVEIA", "grafia conferida",
    "MG", "QUELUZITA", "QUELUZITO", "nome oficial atual",
    "MG", "SANTA RITA DO IBITIPOCA", "SANTA RITA DE IBITIPOCA", "grafia conferida",
    "MG", "SAO THOME DAS LETRAS", "SAO TOME DAS LETRAS", "grafia conferida",
    "MS", "BATAIPORA", "BATAYPORA", "grafia conferida",
    "MT", "POXOREO", "POXOREU", "grafia conferida",
    "MT", "SANTO ANTONIO DO LEVERGER", "SANTO ANTONIO DE LEVERGER", "grafia conferida",
    "PA", "ELDORADO DOS CARAJAS", "ELDORADO DO CARAJAS", "grafia conferida",
    "PA", "SANTA ISABEL DO PARA", "SANTA IZABEL DO PARA", "grafia conferida",
    "PB", "CAMPO DE SANTANA", "TACIMA", "municipio renomeado",
    "PB", "SANTA CECILIA DE UMBUZEIRO", "SANTA CECILIA", "nome oficial atual",
    "PB", "SANTAREM", "JOCA CLAUDINO", "municipio renomeado",
    "PB", "SAO DOMINGOS DE POMBAL", "SAO DOMINGOS", "nome oficial atual",
    "PE", "BELEM DE SAO FRANCISCO", "BELEM DO SAO FRANCISCO", "grafia conferida",
    "PE", "IGUARACI", "IGUARACY", "grafia conferida",
    "PE", "LAGOA DO ITAENGA", "LAGOA DE ITAENGA", "grafia conferida",
    "PR", "4O CENTENARIO", "QUARTO CENTENARIO", "grafia conferida",
    "PR", "BELA VISTA DO CAROBA", "BELA VISTA DA CAROBA", "grafia conferida",
    "RJ", "PARATI", "PARATY", "grafia oficial atual",
    "RJ", "TRAJANO DE MORAIS", "TRAJANO DE MORAES", "grafia conferida",
    "RN", "ACU", "ASSU", "grafia oficial atual",
    "RN", "AUGUSTO SEVERO", "CAMPO GRANDE", "municipio renomeado",
    "RN", "BOA SAUDE", "JANUARIO CICCO", "municipio renomeado",
    "RN", "PRESIDENTE JUSCELINO", "SERRA CAIADA", "municipio renomeado",
    "RO", "ALTA FLORESTA DO OESTE", "ALTA FLORESTA D OESTE", "grafia conferida",
    "RO", "ESPIGAO DO OESTE", "ESPIGAO D OESTE", "grafia conferida",
    "RR", "SAO LUIZ", "SAO LUIZ DO ANAUA", "nome oficial atual",
    "SC", "PRESIDENTE CASTELO BRANCO", "PRESIDENTE CASTELLO BRANCO", "grafia conferida",
    "SE", "AMPARO DE SAO FRANCISCO", "AMPARO DO SAO FRANCISCO", "grafia conferida",
    "SP", "EMBU", "EMBU DAS ARTES", "municipio renomeado",
    "SP", "FLORINIA", "FLORINEA", "grafia conferida",
    "TO", "COUTO DE MAGALHAES", "COUTO MAGALHAES", "nome oficial atual",
    "TO", "FORTALEZA DO TABOCAO", "TABOCAO", "municipio renomeado",
    "TO", "SAO VALERIO DA NATIVIDADE", "SAO VALERIO", "nome oficial atual"
  )

  localidades <- tibble::tribble(
    ~abbrev_state_anp, ~name_muni_anp, ~name_muni_geobr, ~motivo,
    "BA", "SALOBRINHO", "ILHEUS", "localidade vinculada ao municipio",
    "PA", "MONTE DOURADO", "ALMEIRIM", "localidade vinculada ao municipio",
    "PA", "PORTO TROMBETAS", "ORIXIMINA", "localidade vinculada ao municipio",
    "RJ", "PAQUEQUER PEQUENO", "PETROPOLIS", "localidade vinculada ao municipio",
    "RJ", "RETIRO DO MURIAE", "ITAPERUNA", "localidade vinculada ao municipio",
    "SC", "RIO DOS BUGRES", "IMBUIA", "localidade vinculada ao municipio",
    "SP", "PIRAMBOIA", "ANHEMBI", "localidade vinculada ao municipio"
  )

  dplyr::bind_rows(renomeacoes, localidades) |>
    dplyr::mutate(
      nome_anp_norm = normalizar_nome_municipio(name_muni_anp),
      nome_geobr_norm = normalizar_nome_municipio(name_muni_geobr)
    ) |>
    dplyr::select(
      abbrev_state_anp,
      nome_anp_norm,
      nome_geobr_norm,
      motivo
    )
}

correcoes_codigo_conferidas_anp <- function() {
  tibble::tribble(
    ~code_muni_anp, ~abbrev_state_anp, ~name_muni_anp, ~code_muni_corrigido, ~motivo,
    "245306", "RN", "BOA SAUDE", "2405306", "zero ausente no codigo da ANP",
    "1700952", "TO", "ANANAS", "1701002", "codigo historico incorreto",
    "1700952", "TO", "COUTO DE MAGALHAES", "1706001", "codigo historico incorreto",
    "1702750", "TO", "BERNARDO SAYAO", "1703206", "codigo historico incorreto",
    "1702750", "TO", "SAO VALERIO DA NATIVIDADE", "1720499", "codigo historico incorreto"
  ) |>
    dplyr::mutate(
      nome_anp_norm = normalizar_nome_municipio(name_muni_anp)
    ) |>
    dplyr::select(
      code_muni_anp,
      abbrev_state_anp,
      nome_anp_norm,
      code_muni_corrigido,
      motivo_codigo = motivo
    )
}

correcoes_nome_ausente_anp <- function() {
  tibble::tribble(
    ~code_muni_anp, ~abbrev_state_anp, ~name_muni_geobr, ~motivo_nome_ausente,
    "5300108", "DF", "BRASILIA", "nome ausente na linha de GLP de 2012"
  ) |>
    dplyr::mutate(
      nome_geobr_norm_ausente = normalizar_nome_municipio(name_muni_geobr)
    ) |>
    dplyr::select(
      code_muni_anp,
      abbrev_state_anp,
      nome_geobr_norm_ausente,
      motivo_nome_ausente
    )
}

exclusoes_conferidas_anp <- function() {
  tibble::tribble(
    ~abbrev_state_anp, ~name_muni_anp, ~motivo_exclusao,
    "PE", "FERNANDO DE NORONHA", "distrito estadual ausente da referencia municipal do geobr",
    "PR", "UNIAO", "registro agregado que nao identifica municipio"
  ) |>
    dplyr::mutate(
      nome_anp_norm = normalizar_nome_municipio(name_muni_anp)
    ) |>
    dplyr::select(abbrev_state_anp, nome_anp_norm, motivo_exclusao)
}

obter_referencia_municipios_anp <- function() {
  referencia <- geobr::lookup_muni(year = 2022, name_muni = "all")

  if (is.null(referencia) || !nrow(referencia)) {
    stop("Nao foi possivel obter a referencia municipal do geobr.", call. = FALSE)
  }

  referencia <- referencia |>
    dplyr::transmute(
      cod6 = substr(as.character(code_muni), 1L, 6L),
      code_muni = as.character(code_muni),
      name_muni,
      abbrev_state,
      name_region,
      nome_norm = normalizar_nome_municipio(name_muni)
    )

  if (anyDuplicated(referencia$cod6)) {
    stop("A referencia do geobr possui cod6 duplicado.", call. = FALSE)
  }

  if (anyDuplicated(referencia[c("abbrev_state", "nome_norm")])) {
    stop("A referencia do geobr possui nome normalizado duplicado na mesma UF.", call. = FALSE)
  }

  referencia
}

descobrir_links_anp <- function() {
  pagina <- rvest::read_html(URL_ANP)
  configuracao <- configuracao_arquivos_anp()

  links <- pagina |>
    rvest::html_elements("a") |>
    rvest::html_attr("href")
  links <- links[!is.na(links)]
  links <- xml2::url_absolute(links, URL_ANP)

  nomes_links <- vapply(
    links,
    function(link) {
      caminho <- httr::parse_url(link)$path
      if (is.null(caminho) || is.na(caminho)) "" else basename(caminho)
    },
    character(1)
  )

  contagens <- vapply(
    configuracao$nome_origem,
    function(nome) sum(tolower(nomes_links) == tolower(nome), na.rm = TRUE),
    integer(1)
  )

  if (any(contagens != 1L)) {
    problemas <- paste0(
      configuracao$nome_origem[contagens != 1L],
      " (encontrado: ",
      contagens[contagens != 1L],
      ")"
    )
    stop(
      "A pagina da ANP nao apresentou exatamente um link para cada arquivo esperado: ",
      paste(problemas, collapse = "; "),
      call. = FALSE
    )
  }

  indices <- match(tolower(configuracao$nome_origem), tolower(nomes_links))
  dplyr::mutate(configuracao, url = links[indices])
}

baixar_arquivos_anp <- function(configuracao, dir_raw) {
  dir.create(dir_raw, recursive = TRUE, showWarnings = FALSE)

  configuracao$caminho_raw <- purrr::map2_chr(
    configuracao$url,
    configuracao$nome_raw,
    function(url, nome_raw) {
      destino <- file.path(dir_raw, nome_raw)
      resposta <- httr::GET(url, httr::write_disk(destino, overwrite = TRUE))

      if (httr::status_code(resposta) != 200L) {
        stop(
          "Falha ao baixar ", nome_raw,
          " (status ", httr::status_code(resposta), ").",
          call. = FALSE
        )
      }

      message("Baixado: ", nome_raw)
      destino
    }
  )

  configuracao
}

ler_dados_anp <- function(caminho_raw, tipo) {
  dados_brutos <- readr::read_csv2(
    caminho_raw,
    locale = readr::locale(encoding = "UTF-8"),
    show_col_types = FALSE,
    progress = FALSE,
    trim_ws = TRUE
  )

  colunas_comuns <- c(
    "ANO", "C\u00d3DIGO IBGE", "GRANDE REGI\u00c3O", "UF", "MUNIC\u00cdPIO"
  )
  colunas_medidas <- if (identical(tipo, "glp")) c("P13", "OUTROS") else "VENDAS"
  faltantes <- setdiff(c(colunas_comuns, colunas_medidas), names(dados_brutos))

  if (length(faltantes)) {
    stop(
      "Colunas ausentes em ", basename(caminho_raw), ": ",
      paste(faltantes, collapse = ", "),
      call. = FALSE
    )
  }

  dados <- dados_brutos |>
    dplyr::mutate(ano = as.integer(.data[["ANO"]]))

  if (anyNA(dados$ano)) {
    stop("Ha ano ausente ou invalido em ", basename(caminho_raw), ".", call. = FALSE)
  }

  dados <- dados |>
    dplyr::filter(ano >= 2010L) |>
    dplyr::transmute(
      ano,
      code_muni_anp = as.character(.data[["C\u00d3DIGO IBGE"]]),
      name_region_anp = stringr::str_squish(.data[["GRANDE REGI\u00c3O"]]),
      abbrev_state_anp = stringr::str_squish(.data[["UF"]]),
      name_muni_anp = stringr::str_squish(.data[["MUNIC\u00cdPIO"]]),
      dplyr::across(dplyr::all_of(colunas_medidas))
    )

  numero_duplicadas <- sum(duplicated(dados))
  if (numero_duplicadas > 0L) {
    stop(
      "Foram encontradas ", numero_duplicadas,
      " linhas integralmente duplicadas em ", basename(caminho_raw), ".",
      call. = FALSE
    )
  }

  dados
}

reconciliar_municipios_anp <- function(dados, referencia) {
  renomeacoes <- renomeacoes_conferidas_anp()
  correcoes_codigo <- correcoes_codigo_conferidas_anp()
  correcoes_nome_ausente <- correcoes_nome_ausente_anp()
  exclusoes <- exclusoes_conferidas_anp()

  if (anyDuplicated(renomeacoes[c("abbrev_state_anp", "nome_anp_norm")])) {
    stop("A tabela de renomeacoes possui chaves duplicadas.", call. = FALSE)
  }

  dados <- dados |>
    dplyr::mutate(
      linha_anp = dplyr::row_number(),
      nome_anp_norm = normalizar_nome_municipio(name_muni_anp)
    ) |>
    dplyr::left_join(
      exclusoes,
      by = c("abbrev_state_anp", "nome_anp_norm")
    )

  exclusoes_aplicadas <- dados |>
    dplyr::filter(!is.na(motivo_exclusao)) |>
    dplyr::distinct(
      abbrev_state_anp,
      name_muni_anp,
      motivo_exclusao
    )

  if (nrow(exclusoes_aplicadas)) {
    message(
      "Registros excluidos por regras conferidas: ",
      sum(!is.na(dados$motivo_exclusao))
    )
  }

  dados <- dados |>
    dplyr::filter(is.na(motivo_exclusao)) |>
    dplyr::select(-motivo_exclusao) |>
    dplyr::left_join(
      renomeacoes,
      by = c("abbrev_state_anp", "nome_anp_norm")
    ) |>
    dplyr::left_join(
      correcoes_nome_ausente,
      by = c("code_muni_anp", "abbrev_state_anp")
    ) |>
    dplyr::mutate(
      nome_alvo_norm = dplyr::coalesce(
        nome_geobr_norm,
        nome_geobr_norm_ausente,
        nome_anp_norm
      )
    ) |>
    dplyr::left_join(
      correcoes_codigo,
      by = c("code_muni_anp", "abbrev_state_anp", "nome_anp_norm")
    ) |>
    dplyr::mutate(
      code_muni_busca = dplyr::coalesce(code_muni_corrigido, code_muni_anp),
      cod6 = substr(code_muni_busca, 1L, 6L)
    )

  referencia_codigo <- referencia |>
    dplyr::rename(
      code_muni_por_codigo = code_muni,
      name_muni_por_codigo = name_muni,
      abbrev_state_por_codigo = abbrev_state,
      name_region_por_codigo = name_region,
      nome_norm_por_codigo = nome_norm
    )

  referencia_nome <- referencia |>
    dplyr::select(-cod6) |>
    dplyr::rename(
      code_muni_por_nome = code_muni,
      name_muni_por_nome = name_muni,
      abbrev_state_por_nome = abbrev_state,
      name_region_por_nome = name_region,
      nome_norm_por_nome = nome_norm
    )

  dados <- dados |>
    dplyr::left_join(referencia_codigo, by = "cod6") |>
    dplyr::mutate(
      codigo_confere = !is.na(code_muni_por_codigo) &
        abbrev_state_por_codigo == abbrev_state_anp &
        nome_norm_por_codigo == nome_alvo_norm
    ) |>
    dplyr::left_join(
      referencia_nome,
      by = c(
        "abbrev_state_anp" = "abbrev_state_por_nome",
        "nome_alvo_norm" = "nome_norm_por_nome"
      )
    )

  correcao_estatica_invalida <- dados |>
    dplyr::filter(
      !is.na(code_muni_corrigido),
      !codigo_confere | code_muni_por_codigo != code_muni_corrigido
    )

  if (nrow(correcao_estatica_invalida)) {
    stop("Uma correcao estatica de codigo nao confere com o geobr.", call. = FALSE)
  }

  dados <- dados |>
    dplyr::mutate(
      code_muni = dplyr::if_else(
        codigo_confere,
        code_muni_por_codigo,
        code_muni_por_nome
      ),
      name_muni = dplyr::if_else(
        codigo_confere,
        name_muni_por_codigo,
        name_muni_por_nome
      ),
      abbrev_state = dplyr::if_else(
        codigo_confere,
        abbrev_state_por_codigo,
        abbrev_state_anp
      ),
      name_region = dplyr::if_else(
        codigo_confere,
        name_region_por_codigo,
        name_region_por_nome
      )
    )

  divergencias <- dados |>
    dplyr::filter(
      is.na(code_muni) |
        is.na(name_muni) |
        is.na(name_region) |
        abbrev_state != abbrev_state_anp |
        normalizar_nome_municipio(name_muni) != nome_alvo_norm
    ) |>
    dplyr::distinct(
      ano,
      code_muni_anp,
      name_muni_anp,
      abbrev_state_anp,
      code_muni,
      name_muni,
      abbrev_state
    )

  if (nrow(divergencias)) {
    amostra <- paste(
      capture.output(print(utils::head(divergencias, 20L), n = 20L)),
      collapse = "\n"
    )
    stop(
      "Persistem divergencias municipais nao conferidas:\n",
      amostra,
      call. = FALSE
    )
  }

  correcoes_aplicadas <- dados |>
    dplyr::filter(!codigo_confere | !is.na(code_muni_corrigido)) |>
    dplyr::transmute(
      ano,
      code_muni_anp,
      name_muni_anp,
      abbrev_state_anp,
      code_muni,
      name_muni,
      metodo = dplyr::case_when(
        !is.na(code_muni_corrigido) ~ "tabela_codigo",
        TRUE ~ "nome_e_uf"
      )
    ) |>
    dplyr::distinct()

  if (nrow(correcoes_aplicadas)) {
    message(
      "Combinacoes municipio/ano corrigidas apos conferencia: ",
      nrow(correcoes_aplicadas)
    )
  }

  dados_finais <- dados |>
    dplyr::select(
      -linha_anp,
      -nome_anp_norm,
      -nome_geobr_norm,
      -nome_geobr_norm_ausente,
      -nome_alvo_norm,
      -motivo,
      -motivo_nome_ausente,
      -code_muni_corrigido,
      -motivo_codigo,
      -code_muni_busca,
      -cod6,
      -dplyr::ends_with("_por_codigo"),
      -dplyr::ends_with("_por_nome"),
      -codigo_confere,
      -name_region_anp,
      -abbrev_state_anp,
      -name_muni_anp,
      -code_muni_anp
    ) |>
    dplyr::relocate(ano, code_muni, name_muni, abbrev_state, name_region)

  list(
    dados = dados_finais,
    correcoes = correcoes_aplicadas,
    exclusoes = exclusoes_aplicadas
  )
}

validar_chave_anp <- function(dados, tipo, nome_arquivo) {
  chaves <- if (identical(tipo, "glp")) {
    c("ano", "code_muni", "tipo_vasilhame")
  } else {
    c("ano", "code_muni")
  }

  duplicadas <- dados |>
    dplyr::count(dplyr::across(dplyr::all_of(chaves)), name = "n") |>
    dplyr::filter(n > 1L)

  if (nrow(duplicadas)) {
    amostra <- paste(
      capture.output(print(utils::head(duplicadas, 20L), n = 20L)),
      collapse = "\n"
    )
    stop(
      "Ha chaves municipais repetidas em ", nome_arquivo, ":\n",
      amostra,
      call. = FALSE
    )
  }

  invisible(TRUE)
}

somar_preservando_na <- function(x) {
  if (all(is.na(x))) {
    return(NA_real_)
  }

  sum(x, na.rm = TRUE)
}

consolidar_municipios_anp <- function(dados, tipo, nome_arquivo) {
  chaves <- c("ano", "code_muni", "name_muni", "abbrev_state", "name_region")
  medidas <- if (identical(tipo, "glp")) c("P13", "OUTROS") else "VENDAS"

  grupos_repetidos <- dados |>
    dplyr::count(dplyr::across(dplyr::all_of(chaves)), name = "n") |>
    dplyr::filter(n > 1L)

  if (nrow(grupos_repetidos)) {
    message(
      "Grupos municipio/ano consolidados apos a correcao de codigos em ",
      nome_arquivo,
      ": ",
      nrow(grupos_repetidos)
    )
  }

  dados |>
    dplyr::group_by(dplyr::across(dplyr::all_of(chaves))) |>
    dplyr::summarise(
      dplyr::across(dplyr::all_of(medidas), somar_preservando_na),
      .groups = "drop"
    )
}

processar_arquivo_anp <- function(
  caminho_raw,
  tipo,
  nome_parquet,
  referencia,
  dir_parquet
) {
  message("Processando: ", basename(caminho_raw))
  dados <- ler_dados_anp(caminho_raw, tipo)
  resultado_municipios <- reconciliar_municipios_anp(dados, referencia)
  dados <- consolidar_municipios_anp(
    resultado_municipios$dados,
    tipo,
    basename(caminho_raw)
  )

  if (identical(tipo, "glp")) {
    dados <- dados |>
      dplyr::rename(
        vendas_vasilhames_p13_kg = P13,
        vendas_vasilhames_outros_kg = OUTROS
      ) |>
      tidyr::pivot_longer(
        cols = c(vendas_vasilhames_p13_kg, vendas_vasilhames_outros_kg),
        names_to = "tipo_vasilhame",
        values_to = "valor_kg"
      )
  } else {
    dados <- dados |>
      dplyr::rename(vendas_litros = VENDAS)
  }

  if (anyDuplicated(dados)) {
    stop(
      "O tratamento produziu linhas integralmente duplicadas em ",
      basename(caminho_raw),
      ".",
      call. = FALSE
    )
  }

  validar_chave_anp(dados, tipo, basename(caminho_raw))
  dir.create(dir_parquet, recursive = TRUE, showWarnings = FALSE)
  caminho_parquet <- file.path(dir_parquet, nome_parquet)
  arrow::write_parquet(dados, caminho_parquet, compression = "snappy")
  message("Parquet gerado: ", nome_parquet)

  list(
    caminho_parquet = caminho_parquet,
    resumo = tibble::tibble(
      arquivo = nome_parquet,
      linhas = nrow(dados),
      ano_inicial = min(dados$ano),
      ano_final = max(dados$ano),
      correcoes = nrow(resultado_municipios$correcoes),
      exclusoes = nrow(resultado_municipios$exclusoes)
    )
  )
}

publicar_parquets_anp <- function(arquivos_parquet) {
  if (!nzchar(Sys.getenv("GITHUB_PAT"))) {
    stop(
      "GITHUB_PAT nao esta configurado. Configure o token apenas na sessao R ",
      "antes de publicar.",
      call. = FALSE
    )
  }

  for (arquivo in arquivos_parquet) {
    piggyback::pb_upload(
      file = arquivo,
      repo = REPOSITORIO_ANP,
      tag = TAG_RELEASE_ANP,
      overwrite = TRUE,
      show_progress = TRUE
    )
  }

  message(
    "Publicacao concluida na release '", TAG_RELEASE_ANP,
    "' de ", REPOSITORIO_ANP, "."
  )
}

rodar_pipeline_anp <- function(publicar = TRUE) {
  verificar_pacotes_anp(publicar = publicar)

  diretorio_trabalho <- tempfile("anp_combustiveis_")
  dir_raw <- file.path(diretorio_trabalho, "raw")
  dir_parquet <- file.path(diretorio_trabalho, "parquet")
  dir.create(diretorio_trabalho, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(diretorio_trabalho, recursive = TRUE, force = TRUE), add = TRUE)

  configuracao <- descobrir_links_anp()
  configuracao <- baixar_arquivos_anp(configuracao, dir_raw)
  referencia <- obter_referencia_municipios_anp()

  resultados <- purrr::pmap(
    configuracao[c("caminho_raw", "tipo", "nome_parquet")],
    function(caminho_raw, tipo, nome_parquet) {
      processar_arquivo_anp(
        caminho_raw = caminho_raw,
        tipo = tipo,
        nome_parquet = nome_parquet,
        referencia = referencia,
        dir_parquet = dir_parquet
      )
    }
  )

  arquivos_parquet <- vapply(
    resultados,
    function(resultado) resultado$caminho_parquet,
    character(1)
  )

  if (publicar) {
    publicar_parquets_anp(arquivos_parquet)
  } else {
    message("Publicacao desativada; os arquivos temporarios serao removidos.")
  }

  resumo <- dplyr::bind_rows(purrr::map(resultados, "resumo"))
  print(resumo)
  invisible(resumo)
}
