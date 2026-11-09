# Executar da raiz: Rscript scripts_dados/mercado_trabalho.R
# Gera localmente dados/caged_movimentacoes_mensais.parquet para revisão.
# Publicar após revisão: Rscript scripts_dados/mercado_trabalho.R --publicar
# Dependências: datacaged, dplyr, readr, data.table, curl, jsonlite, arrow; 7-Zip.
# Publicação: piggyback, gh e httr, com autenticação do GitHub.
#
# CAGED mensal desde 2010-01 por município, com códigos IBGE de sete dígitos
# compatíveis com geobr. ano/mes referem-se à movimentação, inclusive nos ajustes,
# FOR (fora do prazo) e EXC (exclusões). A metodologia muda em 2020 (serie).
# O antigo usa a competência declarada do arquivo mensal, conforme seu layout.
# Não há substituição pela SEI: saldo estadual não recupera movimentos municipais
# e a planilha de agosto/2009 contém erros de escala nas UFs da região Norte.
#
# O CSV estadual anterior diferia da soma das 27 UFs em TODOS os meses do Novo
# CAGED conferidos, por incluir UF não identificada apenas no Brasil. Agora esses
# movimentos são preservados na saída: code_state=99, abbrev_state="NI", code_muni=NA.
# Município não identificado com UF conhecida mantém a UF e code_muni=NA.
# O dicionário CAGEDEST também usa UF + 9999 para município "Ignorado".
# Não somar totais BR/UF à tabela: cada movimento aparece uma única vez.
# Nas competências cobertas, ausência de linha municipal indica ausência de
# movimentos nas fontes lidas. Competência omitida é lacuna, nunca zero.
#
# Conferência em 2026-11-09: o FTP recuperou 15 das 16 bases problemáticas.
# Março/2011 e CAGEDEST_AJUSTES_102010.7z continuam corrompidos nas duas fontes.
# Por decisão do usuário, omitir março/2011 INTEIRO, inclusive seus ajustes,
# e o ajuste 2010-10. Este ajuste ausente pode alterar contagens e saldos de
# competências anteriores; não é possível quantificar seu efeito sem o arquivo.
# Toda nova fonte sem recuperação por integridade/ausência gera aviso explícito.
# Erros de rede, layout, conteúdo e validação continuam interrompendo a carga.
# FOR/EXC inexistentes em AMBAS as fontes são vazios; erro de rede não é ausência.
# Fonte oficial e layouts: https://www.gov.br/trabalho-e-emprego/pt-br/
# acesso-a-informacao/acoes-e-programas/programas-projetos-acoes-obras-e-atividades/
# estatisticas-trabalho/microdados-rais-e-caged

repo <- "pedreirajr/av_imp_tz"
release_tag <- "data"
inicio <- 201001L

estados <- data.frame(
  code_state = c(11:17, 21:29, 31:33, 35L, 41:43, 50:53, 99L),
  abbrev_state = c("RO", "AC", "AM", "RR", "PA", "AP", "TO", "MA", "PI",
    "CE", "RN", "PB", "PE", "AL", "SE", "BA", "MG", "ES", "RJ", "SP",
    "PR", "SC", "RS", "MS", "MT", "GO", "DF", "NI")
)

conferir_periodos <- function(valores, primeiro = inicio) {
  valores <- sort(unique(valores))
  datas <- as.Date(sprintf("%04d-%02d-01", valores %/% 100, valores %% 100),
    format = "%Y-%m-%d")
  inicio_data <- as.Date(sprintf("%04d-%02d-01", primeiro %/% 100, primeiro %% 100))
  if (!length(valores) || anyNA(datas) || any(valores != as.integer(valores))) {
    stop("Competências ausentes ou inválidas", call. = FALSE)
  }
  if (!identical(datas, seq(inicio_data, max(datas), by = "month"))) {
    stop("Competências ausentes ou inválidas desde ", primeiro, call. = FALSE)
  }
}

localizar_7zip <- function() {
  disponiveis <- unname(Sys.which(c("7z", "7za", "7zz")))
  disponiveis <- disponiveis[nzchar(disponiveis)]
  if (length(disponiveis)) return(disponiveis[1])
  candidatos <- c("C:/Program Files/7-Zip/7z.exe", "C:/Program Files (x86)/7-Zip/7z.exe")
  candidatos <- candidatos[file.exists(candidatos)]
  if (length(candidatos)) candidatos[1] else ""
}

nao_identificado <- function(x) {
  # O layout antigo trunca a máscara "{ñ class}" à largura do campo (UF: "{ñ").
  is.na(x) | x %in% c("", "0", "00", "000000", "0000000", "99", "999999", "9999999") |
    grepl("^\\{", x)
}

municipio_nao_identificado <- function(x, uf) {
  # Aba municipio: ftp://ftp.mtps.gov.br/pdet/microdados/CAGED/CAGEDEST_layout_Atualizado.xls
  # Só reconhecer o código ignorado da própria UF; divergências continuam fatais.
  nao_identificado(x) |
    (uf %in% estados$code_state[estados$code_state != 99L] & x == paste0(uf, "9999"))
}

obter_municipios <- function() {
  # O CAGED suprime o dígito verificador. Usar a tabela oficial evita calculá-lo
  # incorretamente nos códigos IBGE com exceções históricas.
  url <- "https://servicodados.ibge.gov.br/api/v1/localidades/municipios"
  resposta <- curl::curl_fetch_memory(url)
  if (resposta$status_code != 200L) stop("Cadastro IBGE indisponível", call. = FALSE)
  cadastro <- jsonlite::fromJSON(rawToChar(resposta$content))
  municipios <- data.frame(code_muni = as.integer(cadastro$id))
  if (nrow(municipios) < 5500L || anyNA(municipios) ||
      anyDuplicated(municipios) || any(nchar(municipios$code_muni) != 7L)) {
    stop("Cadastro IBGE inválido", call. = FALSE)
  }
  municipios
}

resumir_caged <- function(movimentos, municipios, lacunas = integer()) {
  dados <- dplyr::filter(movimentos, competencia >= inicio, !competencia %in% lacunas)
  # Também normaliza os resumos já existentes, inclusive máscaras truncadas.
  dados$municipio[municipio_nao_identificado(dados$municipio, dados$uf)] <- NA_character_
  codigos <- suppressWarnings(as.integer(dados$municipio))
  seis_digitos <- municipios$code_muni %/% 10L
  if (anyDuplicated(seis_digitos)) stop("Cadastro IBGE ambíguo", call. = FALSE)
  indice <- match(codigos, seis_digitos)
  completos <- !is.na(codigos) & nchar(codigos) == 7L
  indice[completos] <- match(codigos[completos], municipios$code_muni)
  if (any(!is.na(codigos) & is.na(indice)) ||
      any(!is.na(dados$municipio) & !grepl("^[0-9]{6,7}$", dados$municipio))) {
    stop("Município ausente do cadastro IBGE", call. = FALSE)
  }
  dados$code_muni <- municipios$code_muni[indice]
  if (any(!is.na(dados$code_muni) & dados$code_muni %/% 100000L != dados$uf)) {
    stop("UF incompatível com município", call. = FALSE)
  }
  dados |>
    dplyr::mutate(
      ano = as.integer(competencia %/% 100L),
      mes = as.integer(competencia %% 100L),
      code_state = uf,
      serie = ifelse(ano < 2020L, "antigo", "novo")
    ) |>
    dplyr::group_by(ano, mes, code_state, code_muni, serie) |>
    dplyr::summarise(dplyr::across(c(admissoes, desligamentos), sum), .groups = "drop") |>
    dplyr::left_join(estados, by = "code_state") |>
    dplyr::mutate(saldo = admissoes - desligamentos) |>
    dplyr::arrange(ano, mes, code_state, code_muni) |>
    dplyr::select(ano, mes, code_state, abbrev_state, code_muni, serie,
      admissoes, desligamentos, saldo)
}

resumir_arquivo <- function(arquivo, tipo) {
  # O sufixo novo impede reutilizar resumos estaduais de execuções anteriores.
  resumo <- paste0(arquivo, ".municipal-v1.rds")
  if (file.exists(resumo) && file.info(resumo)$mtime >= file.info(arquivo)$mtime) {
    return(readRDS(resumo))
  }
  pasta <- tempfile("caged_extraido_")
  dir.create(pasta)
  on.exit(unlink(pasta, recursive = TRUE), add = TRUE)
  saida <- suppressWarnings(system2(localizar_7zip(),
    c("e", shQuote(arquivo), paste0("-o", shQuote(pasta)), "-y"),
    stdout = TRUE, stderr = TRUE))
  if (!is.null(attr(saida, "status")) && attr(saida, "status") != 0L) {
    stop(errorCondition(paste0("Arquivo corrompido: ", basename(arquivo)),
      class = "caged_corrompido"))
  }
  extraidos <- list.files(pasta, pattern = "\\.(txt|csv)$", full.names = TRUE,
    ignore.case = TRUE)
  if (!length(extraidos)) stop("Arquivo sem microdados: ", arquivo, call. = FALSE)

  competencia <- switch(tipo, ANTIGO = "competenciadeclarada",
    AJUSTES = "competenciamovimentacao", "competenciamov")
  movimento <- if (tipo %in% c("ANTIGO", "AJUSTES")) "saldomov" else "saldomovimentacao"
  campos <- c(competencia, "uf", "municipio", movimento)
  sinal <- if (tipo == "EXC") -1L else 1L
  encoding <- if (tipo %in% c("ANTIGO", "AJUSTES")) "latin1" else "UTF-8"
  normalizar <- function(x) {
    x <- iconv(x, to = "ASCII//TRANSLIT")
    tolower(gsub("[^a-zA-Z0-9]", "", x))
  }
  partes <- lapply(extraidos, function(texto) {
    cabecalho <- readr::read_delim(texto, delim = ";", n_max = 0,
      locale = readr::locale(encoding = encoding), show_col_types = FALSE,
      name_repair = "minimal")
    posicoes <- match(campos, normalizar(names(cabecalho)))
    if (anyNA(posicoes)) stop("Colunas inválidas: ", arquivo, call. = FALSE)
    dados <- suppressWarnings(readr::read_delim(texto, delim = ";", col_select = sort(posicoes),
      col_types = readr::cols(.default = readr::col_character()),
      locale = readr::locale(encoding = encoding), show_col_types = FALSE,
      progress = FALSE, trim_ws = TRUE, lazy = FALSE, name_repair = "minimal"))
    problemas <- readr::problems(dados)
    if (nrow(problemas)) {
      # Junho/2012 mistura linhas normais e linhas com um delimitador final.
      # Só aceitar a coluna extra comprovadamente vazia, sem deslocar campos.
      extra <- ncol(cabecalho) + 1L
      terminal <- problemas$col == extra &
        problemas$expected == paste(ncol(cabecalho), "columns") &
        problemas$actual == paste(extra, "columns")
      if (!all(terminal)) stop("Leitura incompleta: ", arquivo, call. = FALSE)
      completo <- withCallingHandlers(data.table::fread(texto, sep = ";",
        skip = 1L, header = FALSE, select = c(sort(posicoes), extra),
        colClasses = "character", fill = Inf,
        encoding = if (encoding == "latin1") "Latin-1" else "UTF-8",
        showProgress = FALSE), warning = function(w) {
          stop("Leitura incompleta: ", arquivo, call. = FALSE)
        })
      if (ncol(completo) != length(posicoes) + 1L ||
          nrow(completo) != nrow(dados)) {
        stop("Leitura incompleta: ", arquivo, call. = FALSE)
      }
      coluna_extra <- completo[[ncol(completo)]]
      if (any(!is.na(coluna_extra) & nzchar(coluna_extra))) {
        stop("Leitura incompleta: ", arquivo, call. = FALSE)
      }
      dados <- completo[, seq_along(posicoes), with = FALSE]
      names(dados) <- names(cabecalho)[sort(posicoes)]
    }
    if (!nrow(dados)) {
      stop("Leitura incompleta: ", arquivo, call. = FALSE)
    }
    names(dados) <- normalizar(names(dados))
    municipio <- dados$municipio
    municipio[municipio_nao_identificado(municipio, dados$uf)] <- NA_character_
    uf <- dados$uf
    uf[nao_identificado(uf)] <- "99"
    movimento_valor <- suppressWarnings(as.integer(dados[[movimento]]))
    numericos <- c(dados[[competencia]], uf, dados[[movimento]])
    if (anyNA(numericos) || any(!grepl("^-?[0-9]+$", numericos))) {
      stop("Campos inválidos: ", arquivo, call. = FALSE)
    }
    movimentos <- data.frame(
      competencia = suppressWarnings(as.integer(dados[[competencia]])),
      uf = suppressWarnings(as.integer(uf)), municipio = municipio,
      admissoes = as.integer(movimento_valor == 1L) * sinal,
      desligamentos = as.integer(movimento_valor == -1L) * sinal
    )
    datas <- as.Date(sprintf("%04d-%02d-01", movimentos$competencia %/% 100L,
      movimentos$competencia %% 100L), format = "%Y-%m-%d")
    if (anyNA(movimentos[c("competencia", "uf", "admissoes", "desligamentos")]) ||
        anyNA(datas) || any(!movimentos$uf %in% estados$code_state) ||
        any(!movimento_valor %in% c(1L, -1L))) {
      stop("Campos inválidos: ", arquivo, call. = FALSE)
    }
    # Totais anteriores à conversão geográfica conferem se nenhum registro some.
    totais <- movimentos |>
      dplyr::group_by(competencia, uf) |>
      dplyr::summarise(dplyr::across(c(admissoes, desligamentos), sum), .groups = "drop")
    agregado <- movimentos |>
      dplyr::group_by(competencia, uf, municipio) |>
      dplyr::summarise(dplyr::across(c(admissoes, desligamentos), sum), .groups = "drop")
    list(movimentos = agregado, totais = totais)
  })
  resultado <- list(
    movimentos = dplyr::bind_rows(lapply(partes, `[[`, "movimentos")),
    totais = dplyr::bind_rows(lapply(partes, `[[`, "totais"))
  )
  saveRDS(resultado, resumo)
  resultado
}

baixar_arquivo <- function(url, destino) {
  dir.create(dirname(destino), recursive = TRUE, showWarnings = FALSE)
  temporario <- tempfile(tmpdir = dirname(destino), fileext = ".part")
  on.exit(unlink(temporario), add = TRUE)
  resposta <- tryCatch(curl::curl_fetch_disk(url, temporario,
    handle = curl::new_handle(connecttimeout = 30, timeout = 600)), error = identity)
  if (inherits(resposta, "curl_error_remote_file_not_found")) return(FALSE)
  if (inherits(resposta, "error")) stop(resposta)
  if (resposta$status_code %in% c(404L, 550L)) return(FALSE)
  if (resposta$status_code >= 400L || file.info(temporario)$size == 0) {
    stop("Download falhou: ", url, call. = FALSE)
  }
  if (!file.copy(temporario, destino, overwrite = TRUE)) {
    stop("Não foi possível salvar ", destino, call. = FALSE)
  }
  TRUE
}

processar_fonte <- function(fonte, cache, atualizar = FALSE, baixar = baixar_arquivo) {
  erros <- character()
  ausentes <- logical()
  indisponiveis <- logical()
  for (origem in c("espelho", "oficial")) {
    pasta <- if (origem == "espelho") cache else file.path(cache, "oficial")
    caminho <- if (origem == "espelho") {
      sub("NOVO CAGED", "NOVO_CAGED", fonte$caminho, fixed = TRUE)
    } else fonte$caminho
    arquivo <- file.path(pasta, caminho)
    parte <- tryCatch({
      existe <- file.exists(arquivo) && file.info(arquivo)$size > 0
      if ((!existe || atualizar) && !baixar(fonte[[origem]], arquivo)) {
        NULL
      } else {
        resumir_arquivo(arquivo, fonte$tipo)
      }
    }, error = identity)
    if (!inherits(parte, "error") && !is.null(parte)) return(parte)
    ausentes <- c(ausentes, is.null(parte))
    indisponiveis <- c(indisponiveis,
      is.null(parte) || inherits(parte, "caged_corrompido"))
    erros <- c(erros, if (is.null(parte)) "ausente" else conditionMessage(parte))
  }
  if (fonte$tipo %in% c("FOR", "EXC") && all(ausentes)) return(NULL)
  mensagem <- paste0(basename(fonte$caminho), ": espelho: ", erros[1], "; FTP: ", erros[2])
  if (all(indisponiveis)) {
    stop(errorCondition(mensagem, class = "caged_fonte_indisponivel"))
  }
  stop(mensagem, call. = FALSE)
}

listar_fontes <- function() {
  antigo <- datacaged::caged_hf_files(type = "antigo", n = Inf, verbose = FALSE)
  novo <- datacaged::caged_hf_files(type = "novo", n = Inf, verbose = FALSE)
  if (!nrow(antigo) || !nrow(novo)) {
    stop("Catálogos antigo/novo do CAGED indisponíveis", call. = FALSE)
  }
  competencias <- sort(unique(as.integer(c(antigo$competencia, novo$competencia))))
  competencias <- competencias[competencias >= inicio]
  conferir_periodos(competencias)
  fontes <- dplyr::bind_rows(lapply(competencias, function(periodo) {
    ano <- periodo %/% 100L
    mes <- periodo %% 100L
    tipos <- if (ano < 2020L) c("ANTIGO", "AJUSTES") else c("MOV", "FOR", "EXC")
    dplyr::bind_rows(lapply(tipos, function(tipo) {
      nome <- switch(tipo,
        ANTIGO = sprintf("CAGEDEST_%02d%04d.7z", mes, ano),
        AJUSTES = sprintf("CAGEDEST_AJUSTES_%02d%04d.7z", mes, ano),
        paste0("CAGED", tipo, periodo, ".7z"))
      pasta <- switch(tipo, ANTIGO = "CAGED", AJUSTES = "CAGED_AJUSTES", "NOVO CAGED")
      caminho <- paste(pasta, ano, if (ano >= 2020L) paste0(periodo, "/", nome) else nome,
        sep = "/")
      data.frame(tipo = tipo, competencia = periodo, caminho = caminho)
    }))
  }))
  caminho_url <- gsub(" ", "%20", fontes$caminho, fixed = TRUE)
  fontes$espelho <- paste0(
    "https://huggingface.co/datasets/alexsandroprado/caged/resolve/main/",
    sub("NOVO%20CAGED", "NOVO_CAGED", caminho_url, fixed = TRUE))
  fontes$oficial <- paste0("ftp://ftp.mtps.gov.br/pdet/microdados/", caminho_url)
  fontes
}

obter_caged <- function() {
  fontes <- listar_fontes()
  municipios <- obter_municipios()
  cache <- tools::R_user_dir("datacaged", "cache")
  recentes <- tail(sort(unique(fontes$competencia)), 12)
  partes <- list()
  falhas <- character()
  lacunas <- integer()
  for (i in seq_len(nrow(fontes))) {
    fonte <- fontes[i, ]
    message("Processando ", basename(fonte$caminho))
    # Atualizar declarações recentes também recupera FOR/EXC tardios. O resumo
    # usa a competência da movimentação, nunca a competência de deduplicação.
    atualizar <- fonte$competencia >= 202001L && fonte$competencia %in% recentes
    parte <- tryCatch(processar_fonte(fonte, cache, atualizar), error = identity)
    if (inherits(parte, "caged_fonte_indisponivel")) {
      warning("Fonte não recuperada e omitida: ", conditionMessage(parte), call. = FALSE)
      if (fonte$tipo %in% c("ANTIGO", "MOV")) {
        lacunas <- c(lacunas, fonte$competencia)
      }
    } else if (inherits(parte, "error")) {
      falhas <- c(falhas, conditionMessage(parte))
    } else if (!is.null(parte)) {
      partes[[length(partes) + 1L]] <- parte
    }
    gc(FALSE)
  }
  if (length(falhas)) stop("Fontes não recuperadas; publicação cancelada:\n",
    paste(falhas, collapse = "\n"), call. = FALSE)
  movimentos <- dplyr::bind_rows(lapply(partes, `[[`, "movimentos"))
  totais <- dplyr::bind_rows(lapply(partes, `[[`, "totais"))
  # Se faltar a base mensal, nem ajustes legíveis tornam esse mês completo.
  dados <- resumir_caged(movimentos, municipios, lacunas)
  bases <- fontes$competencia[fontes$tipo %in% c("ANTIGO", "MOV")]
  validar_resultado(dados, totais, bases, lacunas)
  dados
}

validar_resultado <- function(dados, totais, competencias_base, lacunas = integer()) {
  conferir_periodos(competencias_base)
  if (any(!lacunas %in% competencias_base)) stop("Lacunas fora do período da base")
  competencias <- dados$ano * 100L + dados$mes
  if (anyNA(competencias) || any(!dados$mes %in% 1:12) ||
      !setequal(competencias, setdiff(competencias_base, lacunas))) {
    stop("Competências do resultado incompletas ou inválidas", call. = FALSE)
  }
  chave <- dados[c("ano", "mes", "code_state", "code_muni")]
  if (!nrow(dados) || anyDuplicated(chave)) stop("Resultado vazio ou duplicado", call. = FALSE)
  obrigatorias <- setdiff(names(dados), "code_muni")
  if (anyNA(dados[obrigatorias])) stop("Campos obrigatórios ausentes", call. = FALSE)
  if (any(dados$saldo != dados$admissoes - dados$desligamentos)) {
    stop("Saldo inconsistente", call. = FALSE)
  }
  siglas <- estados$abbrev_state[match(dados$code_state, estados$code_state)]
  municipio <- dados$code_muni
  if (anyNA(siglas) || any(dados$abbrev_state != siglas) ||
      any(!is.na(municipio) & (nchar(municipio) != 7L |
        municipio %/% 100000L != dados$code_state))) {
    stop("Códigos geográficos inconsistentes", call. = FALSE)
  }
  if (any(dados$serie != ifelse(dados$ano < 2020L, "antigo", "novo"))) {
    stop("Série metodológica inconsistente", call. = FALSE)
  }
  esperado <- totais |>
    dplyr::filter(competencia >= inicio, !competencia %in% lacunas) |>
    dplyr::group_by(competencia, uf) |>
    dplyr::summarise(dplyr::across(c(admissoes, desligamentos), sum), .groups = "drop")
  obtido <- dados |>
    dplyr::mutate(competencia = ano * 100L + mes, uf = code_state) |>
    dplyr::group_by(competencia, uf) |>
    dplyr::summarise(dplyr::across(c(admissoes, desligamentos), sum), .groups = "drop")
  comparacao <- dplyr::full_join(esperado, obtido, by = c("competencia", "uf"),
    suffix = c("_fonte", "_municipios"))
  if (anyNA(comparacao) ||
      any(comparacao$admissoes_fonte != comparacao$admissoes_municipios) ||
      any(comparacao$desligamentos_fonte != comparacao$desligamentos_municipios)) {
    stop("Totais das UFs/Brasil divergem da soma municipal", call. = FALSE)
  }
  invisible(TRUE)
}

preparar_asset <- function(dados, diretorio) {
  dir.create(diretorio, recursive = TRUE, showWarnings = FALSE)
  arquivo <- file.path(diretorio, "caged_movimentacoes_mensais.parquet")
  arrow::write_parquet(dados, arquivo)
  arquivo
}

publicar <- function(arquivo) {
  if (!nzchar(gh::gh_token())) stop("Autenticação do GitHub ausente", call. = FALSE)
  resposta <- piggyback::pb_upload(arquivo, repo = repo, tag = release_tag, overwrite = TRUE)
  httr::stop_for_status(resposta[[1]])
}

executar <- function(args = commandArgs(trailingOnly = TRUE)) {
  if (any(!args %in% "--publicar")) stop("Argumento inválido: ", paste(args, collapse = " "))
  if (.Platform$OS.type == "windows") Sys.setlocale("LC_CTYPE", "Portuguese_Brazil.utf8")
  pacotes <- c("datacaged", "dplyr", "readr", "data.table", "curl", "jsonlite", "arrow")
  if ("--publicar" %in% args) pacotes <- c(pacotes, "piggyback", "gh", "httr")
  faltam <- pacotes[!vapply(pacotes, requireNamespace, logical(1), quietly = TRUE)]
  if (length(faltam)) stop("Instale os pacotes: ", paste(faltam, collapse = ", "))
  if (!nzchar(localizar_7zip())) stop("Instale o 7-Zip para conferir a integridade dos arquivos")
  dados <- obter_caged()
  arquivo <- preparar_asset(dados, "dados")
  if ("--publicar" %in% args) publicar(arquivo)
  message("Parquet validado: ", normalizePath(arquivo, winslash = "/"))
  invisible(arquivo)
}

if (sys.nframe() == 0L) executar()
