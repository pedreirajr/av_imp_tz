# -----------------------------------------------------------------------------
# MUNIC / IBGE — módulo Transporte, por município e edição
#
# Extrai o bloco de transporte da Pesquisa de Informações Básicas Municipais
# (MUNIC) e publica o resultado como asset da release do repositório.
#
# Saídas (nenhuma fica no repositório; tudo vai para tempdir() e sobe à release):
#   munic_transporte.parquet  painel longo: ano x município x variável
#   munic_dicionario.xlsx     código -> descrição, por edição
#
# POR QUE FTP E NÃO `sidrar`/`ibger`
# A MUNIC está no SIDRA (187 tabelas sob a pesquisa "PM", 17 delas de
# transporte), então o `sidrar` funciona. O problema é o produto: o SIDRA
# publica tabulações agregadas, não as respostas do questionário. Para o
# município de São Paulo, a tabela 8453 devolve uma linha ("tem Plano
# Municipal de Transporte? -> 1"), enquanto a planilha do FTP devolve as 96
# variáveis MtraNN daquela edição. Os códigos MtraNN são do questionário e
# não existem no SIDRA, nem o dicionário que os descreve — e a issue pede
# justamente os dois. Cada tabela do SIDRA cobre ainda um quesito de uma
# edição, o que exigiria costurar dezenas delas para reproduzir um arquivo.
#
# FORMATO LONGO, E POR QUÊ
# Os códigos NÃO são estáveis entre edições. Em 2024 o IBGE inseriu o quesito
# "A política de financiamento extratarifário" como MTRA084, deslocando os
# seguintes: o MTRA084 de 2017/2020 ("estrutura do espaço viário") virou
# MTRA085 em 2024. Empilhar as edições numa tabela larga, uma coluna por
# código, misturaria silenciosamente perguntas diferentes na mesma coluna.
# No formato longo o significado vem do dicionário por (ano, variavel), e
# comparar edições passa a ser uma decisão explícita de quem analisa.
#
# EDIÇÕES COBERTAS
# 2017, 2020 e 2024 — as únicas edições da MUNIC com módulo de Transporte,
# conferidas uma a uma no portal do IBGE.
# -----------------------------------------------------------------------------

library(readxl)
library(dplyr)
library(tidyr)
library(purrr)
library(stringr)
library(tibble)
library(arrow)
library(writexl)
library(piggyback)

options(timeout = 600)  # arquivos de 8 a 24 MB; o FTP do IBGE às vezes é lento

REPO <- "pedreirajr/av_imp_tz" # repositório GitHub onde os assets são publicados
TAG  <- "data"                 # release "Dados do Projeto", onde a turma junta os dados

# nada é gravado no repositório: downloads e saídas ficam em pasta temporária
dir_tmp <- file.path(tempdir(), "munic")
dir.create(dir_tmp, recursive = TRUE, showWarnings = FALSE)


# -----------------------------------------------------------------------------
# 1. Fontes (FTP oficial do IBGE)
# -----------------------------------------------------------------------------
fontes <- tibble::tribble(
  ~ano, ~url,
  2017, "https://ftp.ibge.gov.br/Perfil_Municipios/2017/Base_de_Dados/Base_MUNIC_2017_xls.zip",
  2020, "https://ftp.ibge.gov.br/Perfil_Municipios/2020/Base_de_Dados/Base_MUNIC_2020.xlsx",
  2024, "https://ftp.ibge.gov.br/Perfil_Municipios/2024/Base_de_Dados/Base_MUNIC_2024_20251107.xlsx"
)


# -----------------------------------------------------------------------------
# 2. Download (pula se já baixado nesta sessão) e descompactação
# -----------------------------------------------------------------------------
baixar_base <- function(ano, url) {
  destino <- file.path(dir_tmp, basename(url))
  if (!file.exists(destino)) {
    message("Baixando MUNIC ", ano, " ...")
    download.file(url, destino, mode = "wb", quiet = TRUE)
  }
  if (str_detect(destino, "\\.zip$")) {
    pasta <- file.path(dir_tmp, paste0("munic_", ano))
    unzip(destino, exdir = pasta)
    destino <- list.files(pasta, pattern = "\\.xlsx?$", full.names = TRUE,
                          recursive = TRUE)[1]
  }
  destino
}

fontes <- fontes |>
  mutate(arquivo = purrr::map2_chr(ano, url, baixar_base))


# -----------------------------------------------------------------------------
# 3. Funções auxiliares
# -----------------------------------------------------------------------------

# Acha a aba cujo nome contém o padrão (ex.: "transp", "dicion")
achar_aba <- function(arq, padrao) {
  abas <- readxl::excel_sheets(arq)
  hit  <- abas[str_detect(str_to_lower(abas), padrao)]
  if (length(hit) == 0) return(NA_character_)
  hit[1]
}

# Acha a coluna com o código IBGE de 7 dígitos do município
achar_col_codigo <- function(df) {
  candidatas <- names(df)[purrr::map_lgl(df, function(x) {
    x <- as.character(x)
    mean(str_detect(x, "^\\d{7}$"), na.rm = TRUE) > 0.9
  })]
  if (length(candidatas) == 0) stop("Não achei coluna com código de 7 dígitos.")
  candidatas[1]
}


# -----------------------------------------------------------------------------
# 4. Extração do bloco de transporte, já em formato longo
# -----------------------------------------------------------------------------
extrair_transporte <- function(ano, arq) {
  aba <- achar_aba(arq, "transp")
  if (is.na(aba)) stop("MUNIC ", ano, ": nenhuma aba de transporte encontrada.")

  df <- readxl::read_excel(arq, sheet = aba, col_types = "text",
                           .name_repair = "unique_quiet")
  col_cod <- achar_col_codigo(df)
  vars <- grep("^mtra", names(df), ignore.case = TRUE, value = TRUE)

  longo <- df |>
    select(code_muni = all_of(col_cod), all_of(vars)) |>
    pivot_longer(-code_muni, names_to = "variavel", values_to = "valor") |>
    mutate(ano = ano, variavel = toupper(variavel), .before = 1)

  message(sprintf("MUNIC %d | aba '%s' | %s municípios | %d variáveis | %s linhas",
                  ano, aba, format(n_distinct(longo$code_muni), big.mark = ".", decimal.mark = ","),
                  length(vars), format(nrow(longo), big.mark = ".", decimal.mark = ",")))
  longo
}

transporte <- purrr::map2(fontes$ano, fontes$arquivo, extrair_transporte) |>
  bind_rows() |>
  arrange(ano, code_muni, variavel)


# -----------------------------------------------------------------------------
# 5. Dicionário de variáveis (aba da própria planilha)
#    A descrição vem espalhada em colunas conforme o nível hierárquico do
#    quesito; aqui elas viram uma descrição única, e a primeira coluna é
#    preenchida para baixo para recuperar o tema de cada bloco.
# -----------------------------------------------------------------------------
extrair_dicionario <- function(ano, arq) {
  aba <- achar_aba(arq, "dicion")
  if (is.na(aba)) stop("MUNIC ", ano, ": nenhuma aba de dicionário encontrada.")

  d <- readxl::read_excel(arq, sheet = aba, col_types = "text",
                          .name_repair = "unique_quiet")

  col_var <- grep("^vari", names(d), ignore.case = TRUE, value = TRUE)[1]
  cols_txt <- setdiff(names(d), grep("^vari", names(d), ignore.case = TRUE, value = TRUE))

  dic <- d |>
    mutate(tema = tidyr::fill(select(d, all_of(cols_txt[1])), everything(),
                              .direction = "down")[[1]]) |>
    mutate(
      variavel  = toupper(trimws(.data[[col_var]])),
      descricao = apply(select(d, all_of(cols_txt)), 1,
                        function(r) paste(na.omit(trimws(r)), collapse = " > ")),
      ano = ano
    ) |>
    filter(!is.na(variavel), str_detect(variavel, "^MTRA")) |>
    select(ano, variavel, descricao, tema) |>
    distinct(ano, variavel, .keep_all = TRUE)

  message(sprintf("MUNIC %d | dicionário: %d variáveis MTRA", ano, nrow(dic)))
  dic
}

dicionario <- purrr::map2(fontes$ano, fontes$arquivo, extrair_dicionario) |>
  bind_rows() |>
  arrange(ano, variavel)


# -----------------------------------------------------------------------------
# 6. Checagens de integridade
# -----------------------------------------------------------------------------
message(sprintf("\nPainel longo: %s linhas | %d edições | %s municípios",
                format(nrow(transporte), big.mark = ".", decimal.mark = ","),
                n_distinct(transporte$ano),
                format(n_distinct(transporte$code_muni), big.mark = ".", decimal.mark = ",")))

sem_desc <- anti_join(distinct(transporte, ano, variavel), dicionario,
                      by = c("ano", "variavel"))
if (nrow(sem_desc) > 0) {
  warning(nrow(sem_desc), " combinações ano/variável sem descrição no dicionário.")
} else {
  message("Todas as variáveis têm descrição no dicionário correspondente.")
}


# -----------------------------------------------------------------------------
# 7. Gravação em pasta temporária e publicação na release
# -----------------------------------------------------------------------------
f_dados <- file.path(dir_tmp, "munic_transporte.parquet")
f_dic   <- file.path(dir_tmp, "munic_dicionario.xlsx")

write_parquet(transporte, f_dados)
write_xlsx(dicionario, f_dic)

pb_upload(file = c(f_dados, f_dic), repo = REPO, tag = TAG, overwrite = TRUE)
unlink(dir_tmp, recursive = TRUE)

message(sprintf("Publicado em https://github.com/%s/releases/tag/%s", REPO, TAG))
