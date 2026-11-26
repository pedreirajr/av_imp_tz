library(httr)
library(readxl)
library(dplyr)
library(tidyr)
library(stringi)
library(jsonlite)
library(arrow)
library(piggyback)
# archive é necessário para os meses distribuídos em .zip/.rar (2015/2016)

ANO_INICIAL <- 2014                       # 2013 só existe em Access (.mdb)
ANO_FINAL   <- as.integer(format(Sys.Date(), "%Y"))

REPO     <- "pedreirajr/av_imp_tz"
TAG      <- "data"
PUBLICAR <- TRUE                          # FALSE para só gerar o parquet, sem subir no release

URL_BASE   <- "https://www.gov.br"
URL_PAGINA <- paste0(URL_BASE, "/transportes/pt-br/assuntos/transito/conteudo-Senatran/frota-de-veiculos-%d")
URL_IBGE   <- "https://servicodados.ibge.gov.br/api/v1/localidades/municipios"
UA         <- user_agent("Mozilla/5.0")

MESES <- c(janeiro = 1, fevereiro = 2, marco = 3, abril = 4, maio = 5, junho = 6,
           julho = 7, agosto = 8, setembro = 9, outubro = 10, novembro = 11, dezembro = 12)
# abreviações e grafias quebradas que aparecem nos nomes dos arquivos
MESES_ABREV <- c(jan = 1, fev = 2, mar = 3, maro = 3, abr = 4, mai = 5, jun = 6,
                 jul = 7, ago = 8, set = 9, out = 10, nov = 11, dez = 12)

# Grafias do DENATRAN que não batem com o IBGE -> código IBGE
CROSSWALK <- c(
  "BAHIA|LAGEDO DO TABOCAL"                   = 2919058,
  "BAHIA|SANTA TERESINHA"                     = 2928505,
  "GOIAS|BOM JESUS"                           = 5203500, # Bom Jesus de Goiás
  "MATO GROSSO|POXOREO"                       = 5107008,
  "MATO GROSSO|SANTO ANTONIO DO LEVERGER"     = 5107800,
  "MINAS GERAIS|AMPARO DA SERRA"              = 3102506,
  "MINAS GERAIS|BARAO D MONTE ALTO"           = 3105509,
  "MINAS GERAIS|BRASOPOLIS"                   = 3108909,
  "MINAS GERAIS|GOUVEA"                       = 3127602,
  "MINAS GERAIS|QUELUZITA"                    = 3153806,
  "PARA|ELDORADO DOS CARAJAS"                 = 1502954,
  "PARA|SANTA ISABEL DO PARA"                 = 1506500,
  "PARAIBA|CAMPO DE SANTANA"                  = 2516409, # atual Tacima
  "PARAIBA|SANTAREM"                          = 2513653, # atual Joca Claudino
  "PARAIBA|SAO DOMINGOS DE POMBAL"            = 2513968, # atual São Domingos
  "PARANA|BELA VISTA DO CAROBA"               = 4102752,
  "PARANA|MUNHOZ DE MELLO"                    = 4116307,
  "PARANA|PINHAL DO SAO BENTO"                = 4119251,
  "PARANA|SANTA CRUZ DO MONTE CASTELO"        = 4123303,
  "PERNAMBUCO|BELEM DE SAO FRANCISCO"         = 2601607,
  "PERNAMBUCO|IGUARACI"                       = 2606903,
  "PERNAMBUCO|LAGOA DO ITAENGA"               = 2608503,
  "RIO DE JANEIRO|ARMACAO DE BUZIOS"          = 3300233,
  "RIO DE JANEIRO|PARATI"                     = 3303807,
  "RIO DE JANEIRO|TRAJANO DE MORAIS"          = 3305901,
  "RIO GRANDE DO NORTE|ARES"                  = 2401206,
  "RIO GRANDE DO NORTE|BOA SAUDE"             = 2405306, # atual Januário Cicco
  "RIO GRANDE DO NORTE|LAGOA DANTA"           = 2406205,
  "RIO GRANDE DO SUL|SANTANA DO LIVRAMENTO"   = 4317103,
  "RONDONIA|NOVA DO MAMORE"                   = 1100338,
  "RORAIMA|SAO LUIZ"                          = 1400605, # São Luiz do Anauá
  "SANTA CATARINA|BALNEARIO DE PICARRAS"      = 4212809,
  "SANTA CATARINA|LAGEADO GRANDE"             = 4209458,
  "SANTA CATARINA|PRESIDENTE CASTELO BRANCO"  = 4213906,
  "SANTA CATARINA|SAO LOURENCO D OESTE"       = 4216909,
  "SANTA CATARINA|SAO MIGUEL D OESTE"         = 4217204,
  "SAO PAULO|EMBU"                            = 3515004, # Embu das Artes
  "SERGIPE|AMPARO DE SAO FRANCISCO"           = 2800100,
  "TOCANTINS|COUTO DE MAGALHAES"              = 1706001,
  "TOCANTINS|FORTALEZA DO TABOCAO"            = 1708254, # atual Tabocão
  "TOCANTINS|SAO VALERIO DA NATIVIDADE"       = 1720499, # atual São Valério
  "SAO PAULO|IBITIUVA"                        = 3539509, # distrito de Pitangueiras (somado)
  "MARANHAO|GOVERNADOR EDISON LOBAO"          = 2104552  # IBGE renomeou p/ Ribeirãozinho do Maranhão
)


NAO_MUNICIPIO <- c("SEM INFORMACAO", "NAO IDENTIFICADO", "NAO SE APLICA", "SEM COMBUSTIVEL")


#funções auxiliares

# Desfaz textos UTF-8 lidos como latin1 ("InformaÃ§Ã£o" -> "Informação")
corrige_encoding <- function(x) {
  ruim <- !is.na(x) & grepl("Ã", x)
  corrigido <- iconv(x[ruim], from = "UTF-8", to = "latin1")
  Encoding(corrigido) <- "UTF-8"   # os bytes resultantes já são UTF-8 válido
  x[ruim] <- ifelse(is.na(corrigido), x[ruim], corrigido)
  x
}

# Chave de casamento: maiúsculo, sem acento, só letras e espaços
normaliza <- function(x) {
  x <- toupper(stri_trans_general(corrige_encoding(x), "Latin-ASCII"))
  trimws(gsub("\\s+", " ", gsub("[^A-Z]", " ", x)))
}

# Nome de coluna snake_case a partir da categoria de combustível
nome_coluna <- function(x) {
  x <- tolower(stri_trans_general(corrige_encoding(x), "Latin-ASCII"))
  x <- gsub("_+", "_", gsub("[^a-z0-9]", "_", trimws(x)))
  gsub("^_|_$", "", x)
}

# Mês a partir da URL: primeiro a pasta (".../2018/dezembro/..."),
# depois o nome do arquivo (nome completo do mês ou abreviação)
mes_da_url <- function(url) {
  u <- tolower(URLdecode(url))
  pasta <- regmatches(u, regexec("/renavam/\\d{4}/([a-z]+)/", u))[[1]]
  if (length(pasta) == 2 && pasta[2] %in% names(MESES)) return(MESES[[pasta[2]]])

  arq <- sub("/@@download/file$", "", u)
  arq <- sub(".*/", "", arq)
  tokens <- strsplit(arq, "[^a-z]+")[[1]]
  hit <- tokens[tokens %in% names(MESES)]
  if (length(hit)) return(MESES[[hit[1]]])
  # abreviações coladas no ano, ex.: "abr2014", "ago2013"
  tokens <- c(tokens, regmatches(arq, gregexpr("[a-z]{3,4}(?=\\d{2,4})", arq, perl = TRUE))[[1]])
  hit <- tokens[tokens %in% names(MESES_ABREV)]
  if (length(hit)) return(MESES_ABREV[[hit[1]]])
  NA_integer_
}

# Lista os links de combustível de uma página anual
links_do_ano <- function(ano) {
  resp <- GET(sprintf(URL_PAGINA, ano), UA, timeout(120))
  if (status_code(resp) != 200) {
    message(sprintf("  %d: página não encontrada (HTTP %d)", ano, status_code(resp)))
    return(NULL)
  }
  html <- content(resp, as = "text", encoding = "UTF-8")
  hrefs <- regmatches(html, gregexpr('href="[^"]+"', html))[[1]]
  hrefs <- unique(gsub('^href="|"$', "", hrefs))
  hrefs <- hrefs[grepl("combust", hrefs, ignore.case = TRUE) & grepl("@@download", hrefs)]
  if (!length(hrefs)) return(NULL)
  data.frame(
    ano = as.integer(ano),
    mes = vapply(hrefs, mes_da_url, numeric(1), USE.NAMES = FALSE),
    url = ifelse(startsWith(hrefs, "http"), hrefs, paste0(URL_BASE, hrefs))
  )
}

# Extensão do arquivo (os slugs de "centrais-de-conteudo" terminam em "-xlsx")
extensao <- function(url) {
  u <- tolower(sub("/@@download/file$", "", url))
  m <- regmatches(u, regexec("[.-](xlsx|xls|zip|rar|mdb|accdb)$", u))[[1]]
  if (length(m) == 2) m[2] else NA_character_
}

# Baixa e lê a planilha de um mês; devolve data.frame cru (uf, municipio, combustivel, qtd)
le_mes <- function(url) {
  ext <- extensao(url)
  if (is.na(ext) || ext %in% c("mdb", "accdb")) {
    warning("Formato não suportado, ignorado: ", url, call. = FALSE)
    return(NULL)
  }
  dir_tmp <- tempfile("frota_comb_")
  dir.create(dir_tmp)
  on.exit(unlink(dir_tmp, recursive = TRUE), add = TRUE)

  arq <- file.path(dir_tmp, paste0("arquivo.", ext))
  resp <- RETRY("GET", url, UA, timeout(300), write_disk(arq, overwrite = TRUE), times = 3)
  stop_for_status(resp)

  if (ext %in% c("zip", "rar")) {
    if (!requireNamespace("archive", quietly = TRUE))
      stop("Instale o pacote 'archive' para ler arquivos .zip/.rar", call. = FALSE)
    archive::archive_extract(arq, dir = file.path(dir_tmp, "x"))
    arq <- list.files(file.path(dir_tmp, "x"), pattern = "\\.xlsx?$",
                      recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
    if (length(arq) != 1) {
      warning("Arquivo compactado sem planilha única, ignorado: ", url, call. = FALSE)
      return(NULL)
    }
  }

  x <- read_excel(arq, sheet = 1, col_types = "text", .name_repair = "minimal")
  if (ncol(x) < 4) stop("Layout inesperado (", ncol(x), " colunas): ", url)
  x <- x[, 1:4]
  names(x) <- c("uf", "municipio", "combustivel", "qtd")
  x
}


#municípios IBGE 

mun_ibge <- fromJSON(URL_IBGE, simplifyVector = FALSE)
ibge <- data.frame(
  code_muni    = vapply(mun_ibge, function(m) m$id, numeric(1)),
  name_muni    = vapply(mun_ibge, function(m) m$nome, character(1)),
  abbrev_state = vapply(mun_ibge, function(m) m$`regiao-imediata`$`regiao-intermediaria`$UF$sigla, character(1)),
  uf_nome      = vapply(mun_ibge, function(m) m$`regiao-imediata`$`regiao-intermediaria`$UF$nome, character(1))
)
ibge$chave <- paste(normaliza(ibge$uf_nome), normaliza(ibge$name_muni), sep = "|")
stopifnot(!anyDuplicated(ibge$chave))

de_para <- rbind(
  data.frame(chave = ibge$chave, code_muni = ibge$code_muni),
  data.frame(chave = names(CROSSWALK), code_muni = unname(CROSSWALK))
)


#links 

message("Listando arquivos nas páginas da SENATRAN...")
links <- do.call(rbind, lapply(ANO_INICIAL:ANO_FINAL, links_do_ano))
if (anyNA(links$mes)) stop("Não foi possível identificar o mês de: ",
                           paste(links$url[is.na(links$mes)], collapse = "\n"))
links <- links[!duplicated(links[, c("ano", "mes")]), ]
links <- links[order(links$ano, links$mes), ]
message(sprintf("  %d meses encontrados (%02d/%d a %02d/%d)", nrow(links),
                links$mes[1], links$ano[1], links$mes[nrow(links)], links$ano[nrow(links)]))


#download e empilhamento 

lista <- vector("list", nrow(links))
for (i in seq_len(nrow(links))) {
  message(sprintf("  [%d/%d] %d-%02d", i, nrow(links), links$ano[i], links$mes[i]))
  x <- le_mes(links$url[i])
  if (is.null(x)) next
  x$ano <- links$ano[i]
  x$mes <- as.integer(links$mes[i])
  lista[[i]] <- x
}
frota_long <- bind_rows(lista)


# tratamento 

qtd_num <- suppressWarnings(as.numeric(frota_long$qtd))
invalidas <- frota_long[is.na(qtd_num), ]
if (nrow(invalidas)) {
  # tipicamente linhas em branco ou notas de rodapé no fim da planilha
  message(sprintf("  %d linha(s) com quantidade não numérica descartadas, ex.:", nrow(invalidas)))
  print(utils::head(as.data.frame(invalidas), 10))
}

# correções da fonte (ver cabeçalho)
frota_long$qtd <- qtd_num
nov21 <- frota_long$ano == 2021 & frota_long$mes == 11
frota_long$qtd[nov21] <- frota_long$qtd[nov21] / 10
frota_long <- frota_long[!(frota_long$ano == 2021 & frota_long$mes == 12), ]

frota_long <- frota_long |>
  filter(!is.na(qtd), !is.na(uf), !is.na(municipio)) |>   # linhas de total/em branco
  mutate(
    uf_n  = normaliza(uf),
    mun_n = normaliza(municipio),
    chave = paste(uf_n, mun_n, sep = "|"),
    combustivel = nome_coluna(combustivel),
    # jan/2018: "Sem Informação" veio rotulado como "SEM COMBUSTIVEL"
    combustivel = ifelse(combustivel == "sem_combustivel", "sem_informacao", combustivel)
  ) |>
  filter(!(uf_n %in% NAO_MUNICIPIO), !(mun_n %in% NAO_MUNICIPIO)) |>
  left_join(de_para, by = "chave")

sem_codigo <- unique(frota_long$chave[is.na(frota_long$code_muni)])
if (length(sem_codigo)) {
  # erro (e não aviso) para não gerar um painel faltando município sem perceber
  stop(sprintf("%d nome(s) sem código IBGE; incluir no CROSSWALK:\n%s",
               length(sem_codigo), paste(sem_codigo, collapse = "\n")), call. = FALSE)
}

frota_wide <- frota_long |>
  filter(!is.na(code_muni)) |>
  group_by(code_muni, ano, mes, combustivel) |>
  summarise(qtd = sum(qtd), .groups = "drop") |>
  pivot_wider(names_from = combustivel, values_from = qtd, values_fill = 0) |>
  left_join(ibge[, c("code_muni", "name_muni", "abbrev_state")], by = "code_muni") |>
  relocate(code_muni, name_muni, abbrev_state, ano, mes) |>
  mutate(code_muni = as.character(code_muni)) |>
  arrange(code_muni, ano, mes)

# colunas de combustível em ordem alfabética, depois das identificadoras
id_cols <- c("code_muni", "name_muni", "abbrev_state", "ano", "mes")
frota_wide <- frota_wide[, c(id_cols, sort(setdiff(names(frota_wide), id_cols)))]

message(sprintf("Categorias de combustível (%d): %s",
                ncol(frota_wide) - length(id_cols),
                paste(setdiff(names(frota_wide), id_cols), collapse = ", ")))
message(sprintf("Painel final: %s linhas, %d colunas, %d municípios",
                format(nrow(frota_wide), big.mark = ".", decimal.mark = ","),
                ncol(frota_wide), length(unique(frota_wide$code_muni))))


# ---- saída ------------------------------------------------------------------

arquivo_saida <- file.path(tempdir(), "frota_combustivel_mensal_municipio.parquet")
write_parquet(frota_wide, arquivo_saida)
message(sprintf("Arquivo salvo: %s", arquivo_saida))

if (PUBLICAR) {
  # publicação no release via piggyback (a release precisa já existir)
  pb_upload(file = arquivo_saida, repo = REPO, tag = TAG, overwrite = TRUE)
  message(sprintf("Publicado em https://github.com/%s/releases/tag/%s", REPO, TAG))
}
