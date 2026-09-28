# Executar com Rscript scripts_dados/mercado_trabalho.R.
# Dependências: PNADcIBGE, survey, datacaged, readr, readxl, arrow, piggyback, gh, httr.
# O CAGED antigo também requer 7-Zip. Arquivos de trabalho ficam fora do Git.
# Saídas no release "data": PNADc trimestral e CAGED mensal, ambos para BR e 27 UFs.
# O CSV é usado até 100 MiB; acima desse tamanho, publica-se Parquet.
# PNADc: ocupados, desocupados e força de trabalho são estimativas de pessoas;
# taxa_desocupacao está em porcentagem. CAGED: competencia é AAAAMM da
# movimentação; saldo = admissões - desligamentos quando há microdados íntegros.
#
# Limitações do CAGED: na carga conferida em 2026-09, 22 arquivos mensais antigos
# entre 2008-05 e 2014-12 estavam corrompidos. Nesses meses, a coluna "cobertura"
# vale "saldo_apenas_SEI": o saldo vem da planilha pública da SEI/BA, somado aos
# ajustes legíveis; admissões e desligamentos ficam vazios, pois o saldo não permite
# recuperá-los. Se também faltar esse saldo, o mês é omitido com aviso.
# Meses observados (ano: meses): 2008: 05, 08; 2009: 06, 08, 10, 11;
# 2010: 05, 06, 07, 10, 12; 2011: 03; 2012: 05, 06, 08, 10;
# 2013: 01, 10; 2014: 03, 05, 09, 12.
# O ajuste CAGEDEST_AJUSTES_102010.7z também estava corrompido e é omitido.
# "fontes_omitidas" registra essa lacuna em todo o CSV; isso NÃO significa que
# cada linha foi afetada. Não é possível quantificar seu efeito sem o arquivo.
# A série muda de metodologia em 2020 (coluna "serie"); compare os dois trechos
# com essa quebra em mente. Consulte também os avisos da execução.

repo <- "pedreirajr/av_imp_tz"
release_tag <- "data"
limite_csv <- 100 * 1024^2

conferir_periodos <- function(valores, tipo) {
  datas <- as.Date(sprintf("%04d-%02d-01", valores %/% 100, valores %% 100))
  if (anyNA(datas) || !identical(sort(unique(datas)), seq(min(datas), max(datas), by = "month"))) {
    stop("Competências ausentes ou inválidas em ", tipo, call. = FALSE)
  }
}

localizar_7zip <- function() {
  disponiveis <- Sys.which(c("7z", "7za", "7zz"))
  disponiveis <- unname(disponiveis[nzchar(disponiveis)])
  if (length(disponiveis)) return(disponiveis[1])
  candidatos <- c("C:/Program Files/7-Zip/7z.exe",
    "C:/Program Files (x86)/7-Zip/7z.exe")
  candidatos <- candidatos[file.exists(candidatos)]
  if (length(candidatos)) candidatos[1] else ""
}

resumir_pnadc <- function(design, ano, trimestre) {
  # VD4002: 1 = ocupado, 2 = desocupado. svytotal/svyby usam o desenho amostral
  # devolvido pelo PNADcIBGE, incluindo os pesos de expansão.
  design <- subset(design, !is.na(VD4002))
  design <- stats::update(design,
    ocupado = as.numeric(VD4002 == 1),
    desocupado = as.numeric(VD4002 == 2)
  )
  brasil <- survey::svytotal(~ocupado + desocupado, design, na.rm = TRUE)
  ufs <- survey::svyby(~ocupado + desocupado, ~UF, design,
    survey::svytotal, na.rm = TRUE, keep.var = FALSE
  )
  names(ufs) <- sub("^statistic\\.", "", names(ufs))
  totais <- data.frame(
    uf = c("BR", sprintf("%02d", as.integer(as.character(ufs$UF)))),
    ocupados = round(c(unname(coef(brasil)["ocupado"]), ufs$ocupado)),
    desocupados = round(c(unname(coef(brasil)["desocupado"]), ufs$desocupado))
  )
  # As contagens publicadas são pessoas estimadas, arredondadas ao inteiro.
  # A taxa usa essas mesmas contagens, mantendo a identidade da força de trabalho.
  totais$forca_trabalho <- totais$ocupados + totais$desocupados
  totais$taxa_desocupacao <- 100 * totais$desocupados / totais$forca_trabalho
  data.frame(ano = ano, trimestre = trimestre, totais)
}

obter_pnadc <- function() {
  suppressPackageStartupMessages(library("PNADcIBGE", character.only = TRUE))
  cache <- tools::R_user_dir("av_imp_tz_pnadc", "cache")
  dir.create(cache, recursive = TRUE, showWarnings = FALSE)
  hoje <- as.POSIXlt(Sys.Date())
  ultimo_completo <- (hoje$year + 1900) * 4 + (hoje$mon %/% 3)
  periodos <- expand.grid(ano = 2012:(hoje$year + 1900), trimestre = 1:4)
  periodos <- periodos[periodos$ano * 4 + periodos$trimestre <= ultimo_completo, ]
  periodos <- periodos[order(periodos$ano, periodos$trimestre), ]

  baixar <- function(ano, trimestre) {
    pasta <- tempfile("pnadc_")
    dir.create(pasta)
    on.exit(unlink(pasta, recursive = TRUE), add = TRUE)
    PNADcIBGE::get_pnadc(
      year = ano, quarter = trimestre, vars = c("UF", "VD4002"),
      labels = FALSE, deflator = FALSE, design = TRUE,
      reload = FALSE, savedir = pasta
    )
  }
  resumo <- function(ano, trimestre, atualizar = FALSE) {
    # Guardar só o agregado evita baixar novamente todo o microdado trimestral.
    arquivo <- file.path(cache, sprintf("%04dT%d.rds", ano, trimestre))
    if (!atualizar && file.exists(arquivo) &&
        difftime(Sys.time(), file.info(arquivo)$mtime, units = "days") < 7) {
      salvo <- try(readRDS(arquivo), silent = TRUE)
      if (!inherits(salvo, "try-error")) return(salvo)
    }
    design <- baixar(ano, trimestre)
    if (is.null(design)) stop("Falha ao obter PNADc: ", ano, "T", trimestre)
    resultado <- resumir_pnadc(design, ano, trimestre)
    saveRDS(resultado, arquivo)
    resultado
  }
  ultimo <- NULL
  # O trimestre civil mais recente pode ainda não estar no FTP do IBGE.
  # Procuramos o último publicado antes de exigir a sequência desde 2012.
  for (i in rev(seq_len(nrow(periodos)))) {
    tentativa <- try(resumo(periodos$ano[i], periodos$trimestre[i], atualizar = TRUE), silent = TRUE)
    if (!inherits(tentativa, "try-error")) {
      ultimo <- i
      ultimo_resumo <- tentativa
      rm(tentativa)
      break
    }
  }
  if (is.null(ultimo)) stop("Nenhum trimestre da PNADc disponível", call. = FALSE)

  resultado <- vector("list", ultimo)
  for (i in seq_len(ultimo)) {
    if (i == ultimo) {
      resultado[[i]] <- ultimo_resumo
    } else {
      resultado[[i]] <- resumo(periodos$ano[i], periodos$trimestre[i])
    }
  }
  resultado <- do.call(rbind, resultado)
  rownames(resultado) <- NULL
  resultado
}

resumir_caged <- function(partes, ufs, inicio, corrompidos, saldos_sei,
                          fontes_omitidas = character()) {
  dados <- do.call(rbind, partes)
  # Sem microdado íntegro nem saldo alternativo, descartamos a competência
  # corrompida inteira. A lacuna é avisada abaixo e permanece fora do CSV.
  dados <- dados[dados$competencia >= inicio &
    !dados$competencia %in% setdiff(corrompidos, unique(saldos_sei$competencia)), ]
  if (!nrow(dados) || anyNA(dados) || any(!dados$uf %in% c(ufs, 99)) ||
      any(dados$competencia %/% 100 < 1992)) {
    stop("Movimentos inválidos no CAGED", call. = FALSE)
  }
  dados <- aggregate(cbind(admissoes, desligamentos) ~ competencia + uf, dados, sum)
  competencia <- sort(unique(c(dados$competencia, saldos_sei$competencia)))
  datas <- as.Date(sprintf("%04d-%02d-01", competencia %/% 100, competencia %% 100))
  inicio_data <- as.Date(sprintf("%04d-%02d-01", inicio %/% 100, inicio %% 100))
  ausentes <- setdiff(as.integer(format(seq(inicio_data, max(datas), by = "month"),
    "%Y%m")), competencia)
  if (length(ausentes)) warning("Competências CAGED sem microdados nem saldo: ",
    paste(ausentes, collapse = ", "), call. = FALSE)
  # UF 99 (não identificada) integra BR, mas não é publicada como UF. Por isso,
  # em raros meses BR pode diferir da soma das 27 linhas estaduais.
  brasil <- aggregate(cbind(admissoes, desligamentos) ~ competencia, dados, sum)
  brasil <- merge(data.frame(competencia = competencia), brasil,
    by = "competencia", all.x = TRUE)
  brasil$admissoes[is.na(brasil$admissoes)] <- 0
  brasil$desligamentos[is.na(brasil$desligamentos)] <- 0
  dados <- dados[dados$uf %in% ufs, ]
  grade <- expand.grid(competencia = competencia, uf = ufs)
  grade <- merge(grade, dados, by = c("competencia", "uf"), all.x = TRUE)
  grade$admissoes[is.na(grade$admissoes)] <- 0
  grade$desligamentos[is.na(grade$desligamentos)] <- 0
  brasil$uf <- "BR"
  grade$uf <- sprintf("%02d", grade$uf)
  resultado <- rbind(grade[, c("competencia", "uf", "admissoes", "desligamentos")],
    brasil[, c("competencia", "uf", "admissoes", "desligamentos")])
  # A partir de 2020, o Novo CAGED tem outra metodologia: a quebra fica explícita.
  resultado$serie <- ifelse(resultado$competencia < 202001, "antigo", "novo")
  resultado$saldo <- resultado$admissoes - resultado$desligamentos
  resultado$cobertura <- "microdados"
  if (nrow(saldos_sei)) {
    # O saldo da SEI/BA é o saldo mensal básico. Acrescentamos os ajustes
    # legíveis já agregados em "resultado" pela competência da movimentação.
    # O saldo não determina quantas admissões e desligamentos ocorreram.
    chave <- paste(resultado$competencia, resultado$uf)
    indice <- match(paste(saldos_sei$competencia, saldos_sei$uf), chave)
    if (anyNA(indice) || anyDuplicated(indice)) {
      stop("Saldo alternativo incompleto ou duplicado", call. = FALSE)
    }
    resultado$saldo[indice] <- resultado$saldo[indice] + saldos_sei$saldo_base
    resultado$admissoes[indice] <- NA_real_
    resultado$desligamentos[indice] <- NA_real_
    resultado$cobertura[indice] <- "saldo_apenas_SEI"
  }
  # A fonte omitida pode afetar apenas algumas competências, não todas as linhas.
  # Repetir o nome torna a limitação visível mesmo em recortes do CSV.
  resultado$fontes_omitidas <- paste(fontes_omitidas, collapse = ";")
  resultado[order(resultado$competencia, resultado$uf),
    c("competencia", "uf", "serie", "cobertura", "fontes_omitidas",
      "admissoes", "desligamentos", "saldo")]
}

resumir_arquivo <- function(arquivo, tipo) {
  resumo <- paste0(arquivo, ".rds")
  if (file.exists(resumo) && file.info(resumo)$mtime >= file.info(arquivo)$mtime) {
    salvo <- try(readRDS(resumo), silent = TRUE)
    if (!inherits(salvo, "try-error")) return(salvo)
  }
  # No arquivo antigo, a competência é a declarada; nos ajustes e no Novo
  # CAGED, usamos a competência da movimentação. FOR inclui declarações tardias;
  # EXC reverte movimentos excluídos, daí o sinal negativo abaixo.
  posicoes <- switch(tipo, ANTIGO = c(2, 18, 24), AJUSTES = c(2, 15, 20), c(1, 3, 7))
  esperados <- switch(tipo,
    ANTIGO = c("competenciadeclarada", "saldomov", "uf"),
    AJUSTES = c("competenciamovimentacao", "saldomov", "uf"),
    c("competenciamov", "uf", "saldomovimentacao")
  )
  sinal <- if (tipo == "EXC") -1L else 1L
  contar <- function(competencia, movimento, uf) {
    competencia <- as.integer(competencia)
    movimento <- as.integer(movimento)
    uf[grepl("^\\{", uf)] <- "99"
    uf <- as.integer(uf)
    if (anyNA(competencia) || anyNA(uf) || anyNA(movimento) ||
        any(!movimento %in% c(-1L, 1L))) {
      stop("Campos inválidos no arquivo CAGED: ", arquivo, call. = FALSE)
    }
    chave <- competencia * 100L + uf
    contagens <- rowsum(cbind(admissoes = as.integer(movimento == 1L) * sinal,
      desligamentos = as.integer(movimento == -1L) * sinal), chave, reorder = FALSE)
    chaves <- as.integer(rownames(contagens))
    data.frame(competencia = chaves %/% 100L, uf = chaves %% 100L,
      admissoes = contagens[, 1], desligamentos = contagens[, 2])
  }
  ler <- function(origem) {
    dados <- readr::read_delim(origem,
      delim = ";", col_select = posicoes,
      col_types = readr::cols(.default = readr::col_character()),
      locale = readr::locale(encoding = if (tipo %in% c("ANTIGO", "AJUSTES")) "latin1" else "UTF-8"),
      show_col_types = FALSE, progress = FALSE, trim_ws = TRUE, lazy = FALSE,
      name_repair = "minimal")
    nomes <- tolower(gsub("[^a-zA-Z0-9]", "", iconv(names(dados), to = "ASCII//TRANSLIT")))
    if (!identical(nomes, esperados) || !nrow(dados) || nrow(readr::problems(dados))) {
      stop("Colunas inválidas no arquivo CAGED: ", arquivo, call. = FALSE)
    }
    if (tipo %in% c("ANTIGO", "AJUSTES")) {
      contar(dados[[1]], dados[[2]], dados[[3]])
    } else {
      contar(dados[[1]], dados[[3]], dados[[2]])
    }
  }
  pasta <- tempfile("caged_extraido_")
  dir.create(pasta)
  on.exit(unlink(pasta, recursive = TRUE), add = TRUE)
  # Exigir saída 0 do 7-Zip evita aproveitar texto extraído parcialmente de um
  # arquivo com erro de integridade; nesses casos entra o saldo alternativo.
  saida <- suppressWarnings(system2(localizar_7zip(),
    args = c("e", shQuote(arquivo), paste0("-o", shQuote(pasta)), "-y"),
    stdout = TRUE, stderr = TRUE))
  if (!is.null(attr(saida, "status")) && attr(saida, "status") != 0L) {
    stop("Arquivo CAGED ilegível ou corrompido: ", basename(arquivo), call. = FALSE)
  }
  extraidos <- list.files(pasta, pattern = "\\.(txt|csv)$", full.names = TRUE,
    ignore.case = TRUE)
  if (!length(extraidos)) stop("Arquivo CAGED vazio: ", arquivo, call. = FALSE)
  partes <- lapply(extraidos, ler)
  resultado <- do.call(rbind, partes)
  resultado <- aggregate(cbind(admissoes, desligamentos) ~ competencia + uf, resultado, sum)
  saveRDS(resultado, resumo)
  resultado
}

arquivos_ajustes <- function(ajustes) {
  anos <- sort(unique(ajustes$ano))
  cache <- file.path(tools::R_user_dir("datacaged", "cache"), "CAGED_AJUSTES")
  arquivos <- character()
  for (ano in anos) {
    meses <- if (ano <= 2009) 1L else sort(unique(ajustes$mes[ajustes$ano == ano]))
    for (mes in meses) {
      nome <- if (ano <= 2009) sprintf("CAGEDEST_AJUSTES_%04d.7z", ano) else
        sprintf("CAGEDEST_AJUSTES_%02d%04d.7z", mes, ano)
      pasta <- if (ano <= 2009) "2002a2009" else as.character(ano)
      destino <- file.path(cache, pasta, nome)
      if (!file.exists(destino)) {
        dir.create(dirname(destino), recursive = TRUE, showWarnings = FALSE)
        url <- paste("https://huggingface.co/datasets/alexsandroprado/caged/resolve/main",
          "CAGED_AJUSTES", pasta, nome, sep = "/")
        utils::download.file(url, destino, mode = "wb", method = "libcurl", quiet = TRUE)
      }
      if (!file.exists(destino) || file.info(destino)$size == 0) {
        stop("Falha ao baixar ajuste CAGED: ", nome, call. = FALSE)
      }
      arquivos <- c(arquivos, destino)
    }
  }
  arquivos
}

obter_extras <- function(manifest, ajustes) {
  # FOR/EXC marcados "nao_encontrado" no catálogo não têm arquivo a processar.
  # Um arquivo presente porém corrompido é registrado e não interrompe os demais.
  extras <- manifest[manifest$type %in% c("FOR", "EXC") &
    manifest$status != "nao_encontrado", ]
  arquivos_antigos <- arquivos_ajustes(ajustes)
  fontes <- rbind(extras[, c("arquivo", "type")],
    data.frame(arquivo = arquivos_antigos, type = "AJUSTES"))
  saidas <- list()
  omitidas <- character()
  for (i in seq_len(nrow(fontes))) {
    parte <- tryCatch(resumir_arquivo(fontes$arquivo[i], fontes$type[i]),
      error = function(e) e)
    if (inherits(parte, "error")) {
      if (!startsWith(conditionMessage(parte), "Arquivo CAGED ilegível ou corrompido:"))
        stop(parte)
      omitidas <- c(omitidas, basename(fontes$arquivo[i]))
      warning("Fonte CAGED corrompida e omitida: ", tail(omitidas, 1), call. = FALSE)
    } else {
      saidas[[length(saidas) + 1L]] <- parte
    }
  }
  list(partes = saidas, omitidas = omitidas)
}

obter_saldos_sei <- function(competencias) {
  # Fonte alternativa: planilhas anuais de saldo mensal BR/UF da SEI/BA.
  # Elas não trazem as contagens de admissões e desligamentos.
  # https://www.ba.gov.br/sei/caged-0
  vazio <- data.frame(competencia = integer(), uf = character(), saldo_base = numeric())
  if (!length(competencias)) return(vazio)
  cache <- tools::R_user_dir("av_imp_tz_caged", "cache")
  dir.create(cache, recursive = TRUE, showWarnings = FALSE)
  nomes <- c("BRASIL", "NORTE", "RONDONIA", "ACRE", "AMAZONAS", "RORAIMA",
    "PARA", "AMAPA", "TOCANTINS", "NORDESTE", "MARANHAO", "PIAUI", "CEARA",
    "RIO GRANDE DO NORTE", "PARAIBA", "PERNAMBUCO", "ALAGOAS", "SERGIPE",
    "BAHIA", "SUDESTE", "MINAS GERAIS", "ESPIRITO SANTO", "RIO DE JANEIRO",
    "SAO PAULO", "SUL", "PARANA", "SANTA CATARINA", "RIO GRANDE DO SUL",
    "CENTRO-OESTE", "MATO GROSSO", "MATO GROSSO DO SUL", "GOIAS",
    "DISTRITO FEDERAL")
  # A planilha intercala linhas de macrorregião; selecionar BR e as 27 UFs.
  linhas <- c(1L, 3:9, 11:19, 21:24, 26:28, 30:33)
  ufs <- c("BR", sprintf("%02d", c(11:17, 21:29, 31, 32, 33, 35, 41:43,
    51, 50, 52, 53)))
  limpar <- function(x) toupper(iconv(trimws(x), to = "ASCII//TRANSLIT"))
  resultados <- list()
  for (ano in sort(unique(competencias %/% 100))) {
    meses <- competencias[competencias %/% 100 == ano] %% 100
    arquivo <- file.path(cache, sprintf("ind_caged_uf_%d.xls", ano))
    tabela <- tryCatch({
      if (!file.exists(arquivo)) {
        temporario <- tempfile(tmpdir = cache, fileext = ".xls")
        on.exit(unlink(temporario), add = TRUE)
        url <- sprintf(paste0("https://www.ba.gov.br/sei/sites/site-sei/files/",
          "migracao_2024/arquivos/images/releases_mensais/xls/caged/",
          "%d/ind_caged_uf_%d.xls"), ano, ano)
        utils::download.file(url, temporario, mode = "wb", method = "libcurl", quiet = TRUE)
        if (!file.exists(temporario) || file.info(temporario)$size == 0 ||
            !file.rename(temporario, arquivo)) stop("download incompleto")
      }
      x <- readxl::read_excel(arquivo, range = "A5:M37", col_names = FALSE,
        .name_repair = "minimal")
      if (nrow(x) != 33L || ncol(x) != 13L ||
          !identical(limpar(x[[1]]), nomes)) stop("estrutura inesperada da planilha")
      x
    }, error = function(e) {
      warning("Saldo SEI indisponível para ", ano, ": ", conditionMessage(e),
        call. = FALSE)
      NULL
    })
    if (is.null(tabela)) next
    for (mes in meses) {
      valores <- suppressWarnings(as.numeric(tabela[[mes + 1L]][linhas]))
      if (length(valores) != 28L || anyNA(valores)) {
        warning("Saldo SEI inválido para ", ano * 100L + mes, call. = FALSE)
        next
      }
      resultados[[length(resultados) + 1L]] <- data.frame(
        competencia = ano * 100L + mes, uf = ufs, saldo_base = valores)
    }
  }
  if (length(resultados)) do.call(rbind, resultados) else vazio
}

obter_caged <- function() {
  antigo <- datacaged::caged_hf_files(type = "antigo", n = Inf, verbose = FALSE)
  novo <- datacaged::caged_hf_files(type = "novo", n = Inf, verbose = FALSE)
  ajustes <- datacaged::caged_hf_files(type = "ajustes", n = Inf, verbose = FALSE)
  if (!nrow(antigo) || !nrow(novo)) stop("Competências do CAGED indisponíveis", call. = FALSE)
  antigo$competencia <- as.integer(antigo$competencia)
  novo$competencia <- as.integer(novo$competencia)
  ajustes$competencia <- as.integer(ajustes$competencia)
  antigo <- antigo[antigo$competencia >= 200805L, ]
  ajustes <- ajustes[ajustes$competencia >= min(antigo$competencia), ]
  conferir_periodos(sort(unique(c(antigo$competencia, novo$competencia))), "fontes CAGED")
  if (!nzchar(localizar_7zip())) {
    stop("7-Zip é necessário para processar o CAGED antigo", call. = FALSE)
  }
  recentes <- tail(sort(unique(novo$competencia)), 12)
  # Atualizamos os 12 meses de declaração mais recentes para captar revisões,
  # inclusive FOR/EXC tardios. caged_update() deduplica pela competência do
  # arquivo; aqui resumimos cada fonte pela competência da movimentação.
  manifests <- list()
  for (fonte in list(antigo, novo)) {
    for (ano in sort(unique(fonte$ano))) {
      meses <- sort(unique(fonte$mes[fonte$ano == ano]))
      atualizar <- fonte$competencia[fonte$ano == ano & fonte$competencia %in% recentes] %% 100
      for (forcar in c(FALSE, TRUE)) {
        selecionados <- if (forcar) intersect(meses, atualizar) else setdiff(meses, atualizar)
        if (length(selecionados)) {
          manifests[[length(manifests) + 1L]] <- datacaged::caged_download(
            years = ano, months = selecionados, force = forcar)
        }
      }
    }
  }
  manifest <- do.call(rbind, manifests)
  if (nrow(manifest) != nrow(antigo) + 3 * nrow(novo) ||
      any(!manifest$status %in% c("cache", "baixado", "nao_encontrado")) ||
      any(manifest$status == "nao_encontrado" &
        !manifest$type %in% c("FOR", "EXC")) ||
      any(!file.exists(manifest$arquivo[manifest$status != "nao_encontrado"]))) {
    stop("Download CAGED incompleto", call. = FALSE)
  }
  base <- manifest[manifest$type %in% c("ANTIGO", "MOV"), ]
  partes <- list()
  corrompidos <- integer()
  for (i in seq_len(nrow(base))) {
    if (i == 1L || base$mes[i] == 1L) message("Processando CAGED ", base$ano[i])
    parte <- tryCatch(resumir_arquivo(base$arquivo[i], base$type[i]),
      error = function(e) e)
    if (inherits(parte, "error")) {
      # Só o arquivo mensal antigo admite substituição por saldo da SEI/BA.
      # Outros erros de base impedem publicar dados potencialmente incompletos.
      if (base$type[i] != "ANTIGO" ||
          !startsWith(conditionMessage(parte), "Arquivo CAGED ilegível ou corrompido:")) {
        stop(parte)
      }
      corrompidos <- c(corrompidos, base$ano[i] * 100L + base$mes[i])
      warning("Microdados CAGED corrompidos em ", tail(corrompidos, 1),
        "; tentando saldo SEI", call. = FALSE)
    } else {
      partes[[length(partes) + 1L]] <- parte
    }
    gc(FALSE)
  }
  extras <- obter_extras(manifest, ajustes)
  saldos_sei <- obter_saldos_sei(corrompidos)
  resumir_caged(c(partes, extras$partes), datacaged::uf_codigos$codigo,
    min(antigo$competencia), corrompidos, saldos_sei, extras$omitidas)
}

validar_resultado <- function(dados, colunas_periodo) {
  # Toda competência publicada precisa ter BR e 27 UFs, sem duplicatas.
  # NA em admissões/desligamentos só é válido onde a cobertura é apenas saldo.
  chave <- dados[, c(colunas_periodo, "uf")]
  periodo <- do.call(paste, c(dados[colunas_periodo], sep = "-"))
  nao_nulos <- setdiff(names(dados), if ("cobertura" %in% names(dados))
    c("admissoes", "desligamentos") else character())
  if (!nrow(dados) || anyNA(dados[nao_nulos]) || anyDuplicated(chave) ||
      any(table(periodo) != 28) ||
      !setequal(unique(dados$uf), c("BR", sprintf("%02d", datacaged::uf_codigos$codigo)))) {
    stop("Resultado incompleto ou duplicado; publicação cancelada", call. = FALSE)
  }
  if ("cobertura" %in% names(dados) &&
      (any(!dados$cobertura %in% c("microdados", "saldo_apenas_SEI")) ||
       any(is.na(dados$admissoes) != (dados$cobertura == "saldo_apenas_SEI")) ||
       any(is.na(dados$desligamentos) != (dados$cobertura == "saldo_apenas_SEI")))) {
    stop("Cobertura CAGED inconsistente; publicação cancelada", call. = FALSE)
  }
}

preparar_asset <- function(dados, nome, diretorio) {
  csv <- file.path(diretorio, paste0(nome, ".csv"))
  readr::write_csv(dados, csv, na = "")
  if (file.info(csv)$size <= limite_csv) return(csv)
  parquet <- file.path(diretorio, paste0(nome, ".parquet"))
  arrow::write_parquet(dados, parquet)
  unlink(csv)
  parquet
}

publicar <- function(arquivo) {
  # Confirmar o HTTP antes de remover o formato antigo do mesmo resultado.
  resposta <- piggyback::pb_upload(arquivo, repo = repo, tag = release_tag,
    overwrite = TRUE)
  httr::stop_for_status(resposta[[1]])
  extensao_antiga <- if (grepl("\\.csv$", arquivo)) ".parquet" else ".csv"
  piggyback::pb_delete(paste0(tools::file_path_sans_ext(basename(arquivo)), extensao_antiga),
    repo = repo, tag = release_tag)
}

executar <- function() {
  if (.Platform$OS.type == "windows" &&
      is.na(suppressWarnings(Sys.setlocale("LC_CTYPE", "Portuguese_Brazil.utf8")))) {
    stop("Locale UTF-8 indisponível para ler o CAGED antigo", call. = FALSE)
  }
  pacotes <- c("PNADcIBGE", "survey", "datacaged", "readr", "readxl",
    "arrow", "piggyback", "gh", "httr")
  faltam <- pacotes[!vapply(pacotes, requireNamespace, logical(1), quietly = TRUE)]
  if (length(faltam)) stop("Instale os pacotes: ", paste(faltam, collapse = ", "), call. = FALSE)
  if (!nzchar(gh::gh_token())) stop("Autenticação do GitHub ausente", call. = FALSE)
  releases <- piggyback::pb_releases(repo, verbose = FALSE)
  if (!release_tag %in% releases$tag_name) stop("Release 'data' não encontrado", call. = FALSE)

  caged <- obter_caged()
  pnadc <- obter_pnadc()
  # Validar ambas as séries antes do primeiro upload evita publicar uma só.
  validar_resultado(pnadc, c("ano", "trimestre"))
  validar_resultado(caged, "competencia")
  completos <- caged$cobertura == "microdados"
  if (any(pnadc$forca_trabalho != pnadc$ocupados + pnadc$desocupados) ||
      any(caged$saldo[completos] !=
        caged$admissoes[completos] - caged$desligamentos[completos])) {
    stop("Inconsistência nos indicadores; publicação cancelada", call. = FALSE)
  }

  diretorio <- tempfile("assets_mercado_")
  dir.create(diretorio)
  on.exit(unlink(diretorio, recursive = TRUE), add = TRUE)
  arquivos <- c(
    preparar_asset(pnadc, "pnadc_desocupacao_trimestral", diretorio),
    preparar_asset(caged, "caged_movimentacoes_mensais", diretorio)
  )
  invisible(lapply(arquivos, publicar))
  release <- gh::gh("GET /repos/:owner/:repo/releases/tags/:tag",
    owner = "pedreirajr", repo = "av_imp_tz", tag = release_tag)
  nomes <- vapply(release$assets, function(asset) asset$name, character(1))
  if (!all(basename(arquivos) %in% nomes)) {
    stop("Assets publicados não encontrados no release", call. = FALSE)
  }
  print(data.frame(arquivo = nomes, bytes = vapply(release$assets,
    function(asset) asset$size, numeric(1))))
}

if (sys.nframe() == 0L) executar()
