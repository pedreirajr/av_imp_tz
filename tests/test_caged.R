# Executar da raiz: Rscript tests/test_caged.R
Sys.setlocale("LC_CTYPE", "Portuguese_Brazil.utf8")
library(testthat)
source("scripts_dados/mercado_trabalho.R", encoding = "UTF-8")

municipios <- data.frame(code_muni = c(1200401L, 2927408L, 3550308L))
movimentos <- data.frame(
  competencia = c(200912L, 201001L, 201001L, 201001L, 201001L, 201002L),
  uf = c(29L, 29L, 35L, 35L, 99L, 29L),
  municipio = c("292740", "292740", "355030", NA, NA, "292740"),
  admissoes = c(10, 3, 2, 4, 6, 1),
  desligamentos = c(2, 0, 1, 2, 3, 1)
)
totais <- movimentos |>
  dplyr::group_by(competencia, uf) |>
  dplyr::summarise(dplyr::across(c(admissoes, desligamentos), sum), .groups = "drop")

test_that("esquema municipal desde 2010 preserva localizações desconhecidas", {
  resultado <- resumir_caged(movimentos, municipios)
  expect_identical(names(resultado), c("ano", "mes", "code_state", "abbrev_state",
    "code_muni", "serie", "admissoes", "desligamentos", "saldo"))
  expect_type(resultado$ano, "integer")
  expect_type(resultado$mes, "integer")
  expect_true(all(resultado$ano == 2010L))
  expect_equal(resultado$code_muni[!is.na(resultado$code_muni)], c(2927408L, 3550308L, 2927408L))
  expect_equal(sum(resultado$admissoes), 16)
  expect_equal(sum(resultado$desligamentos), 7)
  desconhecida <- subset(resultado, code_state == 99L)
  expect_equal(desconhecida$abbrev_state, "NI")
  expect_true(is.na(desconhecida$code_muni))
  expect_equal(desconhecida$saldo, 3)
  sem_municipio <- subset(resultado, code_state == 35L & is.na(code_muni))
  expect_equal(sem_municipio$admissoes, 4)
  expect_equal(sem_municipio$desligamentos, 2)
  expect_silent(validar_resultado(resultado, totais, c(201001L, 201002L)))
})

test_that("códigos geográficos inválidos não são inventados", {
  errado <- movimentos
  errado$municipio[2] <- "292741"
  expect_error(resumir_caged(errado, municipios), "Município.*IBGE")
  errado$municipio[2] <- "355030"
  expect_error(resumir_caged(errado, municipios), "UF.*município")
  errado$municipio[2] <- "2927409"
  expect_error(resumir_caged(errado, municipios), "Município.*IBGE")
})

test_that("validação impede publicação de totais, chaves ou calendário inválidos", {
  resultado <- resumir_caged(movimentos, municipios)
  expect_error(validar_resultado(resultado, totais, c(201001L, 201003L)), "Competências")
  expect_error(validar_resultado(rbind(resultado, resultado[1, ]), totais,
    c(201001L, 201002L)), "duplicad")
  errado <- resultado
  errado$saldo[1] <- errado$saldo[1] + 1
  expect_error(validar_resultado(errado, totais, c(201001L, 201002L)), "Saldo")
  errado <- resultado
  errado$admissoes[1] <- errado$admissoes[1] + 1000
  errado$saldo[1] <- errado$saldo[1] + 1000
  expect_error(validar_resultado(errado, totais, c(201001L, 201002L)), "Totais")
  errado <- resultado
  errado$mes[1] <- 13L
  expect_error(validar_resultado(errado, totais, c(201001L, 201002L)), "Competências")
  errado <- resultado
  errado$abbrev_state[1] <- "SP"
  expect_error(validar_resultado(errado, totais, c(201001L, 201002L)), "geogr")
})

criar_arquivo <- function(pasta, nome, cabecalho, linhas) {
  texto <- file.path(pasta, paste0(nome, ".txt"))
  writeLines(c(cabecalho, linhas), texto, useBytes = TRUE)
  arquivo <- file.path(pasta, paste0(nome, ".7z"))
  status <- system2(localizar_7zip(), c("a", "-t7z", shQuote(arquivo), shQuote(texto)),
    stdout = FALSE, stderr = FALSE)
  stopifnot(status == 0L)
  arquivo
}

test_that("município Ignorado do dicionário oficial preserva UF e totais", {
  dados <- movimentos[2, ]
  dados$municipio <- "299999"
  resultado <- resumir_caged(dados, municipios)
  expect_true(is.na(resultado$code_muni))
  expect_equal(resultado$code_state, 29L)
  expect_equal(resultado$admissoes, 3)
  expect_equal(resultado$desligamentos, 0)
  dados$municipio <- "359999"
  expect_error(resumir_caged(dados, municipios), "Município.*IBGE")
  pasta <- tempfile()
  dir.create(pasta)
  on.exit(unlink(pasta, recursive = TRUE))
  arquivo <- criar_arquivo(pasta, "ignorado", "Competencia Declarada;Municipio;Saldo Mov;UF",
    "201001;299999;1;29")
  expect_true(is.na(resumir_arquivo(arquivo, "ANTIGO")$movimentos$municipio))
})

test_that("layouts antigo, ajuste, MOV, FOR e EXC usam competência do movimento", {
  pasta <- tempfile()
  dir.create(pasta)
  on.exit(unlink(pasta, recursive = TRUE))
  antigo <- criar_arquivo(pasta, "antigo", "Competencia Declarada;Municipio;Saldo Mov;UF",
    c("201001;292740;1;29", "201001;292740;1;29", "201001;292740;-1;29"))
  for_arquivo <- criar_arquivo(pasta, "for", "competenciamov;uf;municipio;saldomovimentacao",
    "201001;29;292740;1")
  exc <- criar_arquivo(pasta, "exc", "competenciamov;uf;municipio;saldomovimentacao",
    "201001;29;292740;-1")
  partes <- lapply(list(c(antigo, "ANTIGO"), c(for_arquivo, "FOR"), c(exc, "EXC")),
    function(x) resumir_arquivo(x[1], x[2]))
  resultado <- resumir_caged(dplyr::bind_rows(lapply(partes, `[[`, "movimentos")), municipios)
  expect_equal(resultado$admissoes, 3)
  expect_equal(resultado$desligamentos, 0)
  expect_equal(resultado$saldo, 3)
  ajuste <- criar_arquivo(pasta, "ajuste", "Competencia Movimentacao;Municipio;Saldo Mov;UF",
    "201001;292740;1;29")
  expect_equal(resumir_arquivo(ajuste, "AJUSTES")$movimentos$admissoes, 1)
  mov <- criar_arquivo(pasta, "mov", "competenciamov;uf;municipio;saldomovimentacao",
    c("202001;99;999999;1", "202001;{ñclass};{ñclass};-1"))
  novo <- resumir_caged(resumir_arquivo(mov, "MOV")$movimentos, municipios)
  expect_equal(novo$serie, "novo")
  expect_equal(novo$code_state, 99L)
  expect_true(is.na(novo$code_muni))
  expect_equal(novo$admissoes, 1)
  expect_equal(novo$desligamentos, 1)
  # Resumo estadual antigo não pode substituir o novo cache municipal.
  saveRDS(data.frame(uf = 29L, admissoes = 999), paste0(antigo, ".rds"))
  expect_equal(sum(resumir_arquivo(antigo, "ANTIGO")$movimentos$admissoes), 2)
  ruim <- criar_arquivo(pasta, "ruim", "competenciamov;uf;municipio;saldomovimentacao",
    "202013;29;292740;2")
  expect_error(resumir_arquivo(ruim, "MOV"), "inválid")
})

test_that("fonte corrompida é recuperada no FTP ou interrompe a carga", {
  pasta <- tempfile()
  dir.create(pasta)
  on.exit(unlink(pasta, recursive = TRUE))
  bom <- criar_arquivo(pasta, "oficial", "Competencia Declarada;Municipio;Saldo Mov;UF",
    "201005;292740;1;29")
  ruim <- file.path(pasta, "espelho.7z")
  writeLines("corrompido", ruim)
  fonte <- data.frame(tipo = "ANTIGO", competencia = 201005L,
    espelho = ruim, oficial = bom, caminho = "CAGED/2010/CAGEDEST_052010.7z")
  baixar_local <- function(url, destino) {
    dir.create(dirname(destino), recursive = TRUE, showWarnings = FALSE)
    file.copy(url, destino, overwrite = TRUE)
  }
  recuperado <- processar_fonte(fonte, pasta, baixar = baixar_local)
  expect_equal(recuperado$movimentos$admissoes, 1)
  fonte$oficial <- ruim
  expect_error(processar_fonte(fonte, file.path(pasta, "falha"), baixar = baixar_local),
    "CAGEDEST_052010.*espelho.*FTP")
  expect_error(processar_fonte(fonte, file.path(pasta, "falha_tipada"), baixar = baixar_local),
    class = "caged_fonte_indisponivel")
  fonte$tipo <- "FOR"
  ausente <- function(url, destino) FALSE
  expect_null(processar_fonte(fonte, file.path(pasta, "ausente"), baixar = ausente))
  falha_rede <- function(url, destino) stop("timeout")
  expect_error(processar_fonte(fonte, file.path(pasta, "rede"), baixar = falha_rede), "timeout")
  erro_rede <- tryCatch(processar_fonte(fonte, file.path(pasta, "rede_tipada"),
    baixar = falha_rede), error = identity)
  expect_false(inherits(erro_rede, "caged_fonte_indisponivel"))
})

test_that("layout antigo aceita admissão 01 e rejeita números fracionários", {
  pasta <- tempfile()
  dir.create(pasta)
  on.exit(unlink(pasta, recursive = TRUE))
  arquivo <- criar_arquivo(pasta, "zero", "Competencia Declarada;Municipio;Saldo Mov;UF",
    c("201005;292740;01;29", "201005;292740;-1;29"))
  parte <- resumir_arquivo(arquivo, "ANTIGO")
  expect_equal(parte$movimentos$admissoes, 1)
  expect_equal(parte$movimentos$desligamentos, 1)
  fracao <- criar_arquivo(pasta, "fracao", "Competencia Declarada;Municipio;Saldo Mov;UF",
    "201005;292740;1.5;29")
  expect_error(resumir_arquivo(fracao, "ANTIGO"), "Campos inválidos")
})

test_that("escrita é sempre Parquet, com esquema preservado", {
  pasta <- tempfile()
  dir.create(pasta)
  on.exit(unlink(pasta, recursive = TRUE))
  resultado <- resumir_caged(movimentos, municipios)
  arquivo <- preparar_asset(resultado, pasta)
  expect_identical(basename(arquivo), "caged_movimentacoes_mensais.parquet")
  expect_false(any(grepl("csv$", list.files(pasta))))
  expect_equal(as.data.frame(arrow::read_parquet(arquivo)), as.data.frame(resultado))
})

test_that("execução local não publica e falha de carga impede upload", {
  pasta <- tempfile()
  dir.create(pasta)
  on.exit(unlink(pasta, recursive = TRUE))
  ambiente <- new.env(parent = globalenv())
  sys.source("scripts_dados/mercado_trabalho.R", envir = ambiente)
  ambiente$obter_caged <- function() resumir_caged(movimentos, municipios)
  ambiente$preparar_asset <- function(dados, diretorio) preparar_asset(dados, pasta)
  publicado <- character()
  ambiente$publicar <- function(arquivo) publicado <<- arquivo
  arquivo <- ambiente$executar(character())
  expect_true(file.exists(arquivo))
  expect_length(publicado, 0)
  ambiente$executar("--publicar")
  expect_identical(publicado, arquivo)
  publicado <- character()
  ambiente$obter_caged <- function() stop("Fonte incompleta")
  expect_error(ambiente$executar("--publicar"), "Fonte incompleta")
  expect_length(publicado, 0)
})

test_that("catálogo ausente não vira série histórica truncada", {
  for (ausente in c("antigo", "novo")) {
    local_mocked_bindings(caged_hf_files = function(type, ...) {
      if (type == ausente) data.frame(competencia = integer()) else
        data.frame(competencia = 201001L)
    }, .package = "datacaged")
    expect_error(listar_fontes(), "Catálogos antigo/novo.*indisponíveis")
  }
})

test_that("lacuna autorizada omite o mês inteiro e preserva demais movimentos", {
  ambiente <- new.env(parent = globalenv())
  sys.source("scripts_dados/mercado_trabalho.R", envir = ambiente)
  ambiente$obter_municipios <- function() municipios
  ambiente$listar_fontes <- function() data.frame(
    tipo = c("ANTIGO", "ANTIGO", "AJUSTES", "AJUSTES"),
    competencia = c(201001L, 201002L, 201001L, 201002L), caminho = letters[1:4])
  ambiente$processar_fonte <- function(fonte, ...) {
    if (fonte$competencia == 201001L) {
      stop(errorCondition("arquivo corrompido nas duas fontes", class = "caged_fonte_indisponivel"))
    }
    dados <- if (fonte$tipo == "ANTIGO") {
      data.frame(competencia = 201002L, uf = 29L, municipio = "292740",
        admissoes = 1, desligamentos = 0)
    } else {
      # Ajuste legível do mês cuja base falta também deve desaparecer.
      data.frame(competencia = c(201001L, 201002L), uf = 29L, municipio = "292740",
        admissoes = c(100, 2), desligamentos = c(20, 1))
    }
    list(movimentos = dados, totais = dplyr::select(dados, -municipio))
  }
  avisos <- character()
  resultado <- withCallingHandlers(ambiente$obter_caged(), warning = function(w) {
    avisos <<- c(avisos, conditionMessage(w))
    invokeRestart("muffleWarning")
  })
  expect_length(avisos, 2)
  expect_true(all(grepl("Fonte não recuperada e omitida", avisos)))
  expect_equal(resultado$mes, 2L)
  expect_equal(resultado$admissoes, 3)
  expect_equal(resultado$desligamentos, 1)
  expect_equal(resultado$saldo, 2)
  # Rede e layout não são convertidos em lacuna, mesmo com geração parcial.
  ambiente$processar_fonte <- function(...) stop("timeout na fonte")
  expect_error(ambiente$obter_caged(), "publicação cancelada.*|Fontes não recuperadas")
})

test_that("máscaras truncadas do CAGED antigo preservam localização desconhecida", {
  pasta <- tempfile()
  dir.create(pasta)
  on.exit(unlink(pasta, recursive = TRUE))
  arquivo <- criar_arquivo(pasta, "mascara", "Competencia Declarada;Municipio;Saldo Mov;UF",
    c("201101;{ñ cla;01;{ñ", "201101;{ñ cla;-1;29"))
  parte <- resumir_arquivo(arquivo, "ANTIGO")
  resultado <- resumir_caged(parte$movimentos, municipios)
  expect_equal(sum(resultado$admissoes), 1)
  expect_equal(sum(resultado$desligamentos), 1)
  expect_true(all(is.na(resultado$code_muni)))
  expect_equal(resultado$code_state, c(29L, 99L))
  # A conversão também corrige o município mascarado de um resumo já salvo.
  salvo <- movimentos[2, ]
  salvo$municipio <- "{ñ cla"
  expect_true(is.na(resumir_caged(salvo, municipios)$code_muni))
})

test_that("coluna terminal vazia não desloca campos nem descarta registros", {
  pasta <- tempfile()
  dir.create(pasta)
  on.exit(unlink(pasta, recursive = TRUE))
  cabecalho <- "Competencia Declarada;Municipio;Saldo Mov;UF"
  arquivo <- criar_arquivo(pasta, "terminal", cabecalho,
    c("201206;292740;01;29", "201206;355030;-1;35;"))
  parte <- resumir_arquivo(arquivo, "ANTIGO")
  expect_equal(sum(parte$movimentos$admissoes), 1)
  expect_equal(sum(parte$movimentos$desligamentos), 1)
  expect_equal(parte$movimentos$municipio, c("292740", "355030"))
  preenchida <- criar_arquivo(pasta, "extra_preenchida", cabecalho,
    c("201206;292740;01;29", "201206;355030;-1;35;999"))
  expect_error(resumir_arquivo(preenchida, "ANTIGO"), "Leitura incompleta")
  faltando <- criar_arquivo(pasta, "obrigatorio_ausente", cabecalho,
    c("201206;292740;01;29", "201206;355030;-1"))
  expect_error(resumir_arquivo(faltando, "ANTIGO"), "Leitura incompleta|Campos inválidos")
})
