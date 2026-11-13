# 1. VERIFICAÇÃO E INSTALAÇÃO DOS PACOTES

.pkgs <- c(
  "httr2",
  "jsonlite",
  "tidyr",
  "dplyr",
  "readr",
  "arrow",
  "piggyback",
  "geobr",
  "gh"
)

.falta <- .pkgs[
  !vapply(.pkgs, requireNamespace, logical(1), quietly = TRUE)
]

if (length(.falta) > 0) {
  install.packages(.falta, repos = "https://cloud.r-project.org")
}

invisible(
  lapply(.pkgs, library, character.only = TRUE)
)


# 2. DOWNLOAD DOS DADOS DA FIRJAN

# Página do IFGF Firjan: https://www.firjan.com.br/ifgf/
# Para localizar a URL dos dados: abrir a página no navegador, pressionar F12,
# acessar a aba Network (Rede), filtrar por Fetch/XHR e recarregar.
# Identificar a requisição que retorna o JSON dos indicadores.
# Nota: o nome do arquivo JSON (ex: dados-2025-final.json) muda a cada edição do índice.

url <- paste0(
  "https://firjan.com.br/data/files/",
  "E0/01/68/8E/F4D4991031B91689D8284EA8/",
  "dados-2025-final.json"
)

message("Baixando dados da Firjan...")

req <- request(url) |>
  req_user_agent(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  )

resp <- req_perform(req)

raw_data <- resp_body_json(
  resp,
  simplifyVector = TRUE
)


# 3. PROCESSAMENTO E VALIDAÇÃO DA ESTRUTURA INICIAL

if (is.list(raw_data) && "rows" %in% names(raw_data)) {
  df_wide <- as_tibble(raw_data$rows)
} else {
  df_wide <- as_tibble(raw_data)
}

stopifnot(
  "Variáveis críticas ausentes na resposta JSON" =
    all(c("Ano", "IdCidade") %in% names(df_wide))
)

# Mantém IdCidade para posterior exclusão.
df_wide <- df_wide |>
  mutate(
    IdCidade = as.character(IdCidade)
  )


# 4. ADEQUAÇÃO DOS DADOS COM O GEOBR

message("Buscando tabela de referência geográfica no geobr...")

muni_geo <- geobr::lookup_muni(
  year = 2022,
  name_muni = "all"
) |>
  select(
    code_muni,
    code_state,
    abbrev_state,
    name_muni
  ) |>
  distinct(code_muni, .keep_all = TRUE) |>
  mutate(
    code_muni = as.character(code_muni),
    code_muni_6 = substr(code_muni, 1, 6)
  )

# Padroniza a chave da Firjan e realiza o join.
# Nomes e UFs finais serão provenientes exclusivamente do geobr.

df_wide <- df_wide |>
  mutate(
    code_muni_6 = sprintf(
      "%06d",
      as.integer(IdCidade)
    )
  ) |>
  left_join(
    muni_geo |>
      select(
        code_muni_6,
        code_muni,
        code_state,
        abbrev_state,
        name_muni
      ),
    by = "code_muni_6"
  )


# 5. EXCLUSÃO E VALIDAÇÃO DOS MUNICÍPIOS

# Boa Esperança do Norte (MT) - IdCidade 510183:
# O município é mapeado no geobr (código 5101837), porém todos os 12 anos de dados 
# constam como "Dados Indisponíveis" na base da Firjan. Necessária a exclusão manual.
df_wide <- df_wide |>
  filter(IdCidade != "510183")

# A execução trava se algum município não casar com o geobr.

stopifnot(
  "Existem municípios sem correspondência no geobr" =
    !anyNA(df_wide$code_muni)
)

message(
  sprintf(
    "Municípios pareados com sucesso: %d de %d linhas",
    sum(!is.na(df_wide$code_muni)),
    nrow(df_wide)
  )
)

# Remove identificadores originais da Firjan.
df_wide <- df_wide |>
  select(
    -any_of(
      c(
        "Município",
        "Cidade",
        "UF",
        "IdCidade",
        "code_muni_6"
      )
    )
  )


# 6. TRANSFORMAÇÃO PARA FORMATO LONGO

id_vars_padrao <- c(
  "Ano",
  "code_muni",
  "name_muni",
  "abbrev_state",
  "code_state"
)

stopifnot(
  "Variáveis identificadoras ausentes" =
    all(id_vars_padrao %in% names(df_wide))
)

df_long <- df_wide |>
  pivot_longer(
    cols = -all_of(id_vars_padrao),
    names_to = "Indicador_ou_Ranking",
    values_to = "valor",
    values_transform = list(valor = as.character)
  ) |>
  rename(ano = Ano) |>
  mutate(
    ano = as.integer(ano),
    code_muni = as.integer(code_muni),
    code_state = as.integer(code_state),

    # Tratamento do valor ausente utilizado pela Firjan.
    valor_clean = na_if(
      valor,
      "Dados Indisponíveis"
    ),

    # Conversão para valor numérico.
    valor = as.numeric(valor_clean),

    # Classificação dos indicadores e rankings.
    tipo = case_when(
      grepl(
        "^Ranking.*Estadual",
        Indicador_ou_Ranking,
        ignore.case = TRUE
      ) ~ "ranking_estadual",

      grepl(
        "^Ranking.*Nacional",
        Indicador_ou_Ranking,
        ignore.case = TRUE
      ) ~ "ranking_nacional",

      TRUE ~ "indice"
    ),

    # Limpeza do nome do indicador.
    indicador = sub(
      "^[0-9]+",
      "",
      Indicador_ou_Ranking
    ),

    indicador = sub(
      "^(Ranking\\s*(Estadual|Nacional)|Ranking|Valor)\\s*",
      "",
      indicador,
      ignore.case = TRUE
    ),

    indicador = tolower(indicador),

    indicador = gsub(
      "[^[:alnum:]]",
      "",
      indicador
    )
  ) |>
  select(
    -Indicador_ou_Ranking,
    -valor_clean
  )


# 7. VALIDAÇÃO DOS INDICADORES

message("\n--- Indicadores encontrados ---")

print(
  df_long |>
    distinct(indicador, tipo) |>
    arrange(indicador, tipo)
)

message("\n--- Exemplo das primeiras linhas ---")

print(
  head(
    df_long |>
      select(
        ano,
        code_muni,
        code_state,
        abbrev_state,
        name_muni,
        indicador,
        tipo,
        valor
      ),
    15
  )
)

message(
  sprintf(
    "\nTotal de linhas extraídas: %s",
    format(
      nrow(df_long),
      big.mark = ".",
      decimal.mark = ","
    )
  )
)


# 8. EXPORTAÇÃO EM PARQUET

parquet_path <- file.path(
  tempdir(),
  "firjan_dados_longo_completo.parquet"
)

write_parquet(
  x = df_long,
  sink = parquet_path,
  compression = "snappy"
)

message("Arquivo Parquet criado com sucesso.")

# Verifica se o arquivo foi realmente criado.
stopifnot(file.exists(parquet_path))


# 9. UPLOAD VIA PIGGYBACK

# Verifica se há token do GitHub autenticado (via GITHUB_PAT ou gitcreds/gh).

if (!nzchar(gh::gh_token())) {
  stop(
    "Nenhum token do GitHub foi detectado. ",
    "Configure a variável GITHUB_PAT ou registre as credenciais via gitcreds/gh antes de executar."
  )
}

message("Iniciando upload para o GitHub...")

tryCatch(
  {
    pb_upload(
      file = parquet_path,
      repo = "pedreirajr/av_imp_tz",
      tag = "data",
      overwrite = TRUE
    )

    # Só remove o arquivo após o upload não retornar erro.
    unlink(parquet_path)

    message(
      "Upload concluído com sucesso e arquivo temporário removido."
    )
  },
  error = function(e) {

    message(
      "Falha no upload: ",
      conditionMessage(e)
    )

    message(
      "O arquivo Parquet foi preservado em: ",
      parquet_path
    )

    stop("Interrompendo script devido à falha no upload para o GitHub.", call. = FALSE)
  }
)
