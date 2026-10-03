# 1. Verificação e instalação de pacotes necessários no R
.pkgs <- c("httr2", "jsonlite", "tidyr", "dplyr", "readr", "arrow", "piggyback", "geobr", "sf")
.falta <- .pkgs[!vapply(.pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(.falta)) install.packages(.falta, repos = "https://cloud.r-project.org")

invisible(lapply(.pkgs, library, character.only = TRUE))

# 2. DOWNLOAD DOS DADOS (FIRJAN)
url <- "https://firjan.com.br/data/files/E0/01/68/8E/F4D4991031B91689D8284EA8/dados-2025-final.json" 

message("Baixando dados da Firjan...")
req <- request(url) %>%
  req_user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")

resp <- req_perform(req)
raw_data <- resp_body_json(resp, simplifyVector = TRUE)

# 3. PROCESSAMENTO E VALIDAÇÃO DA ESTRUTURA INICIAL
if (is.list(raw_data) && "rows" %in% names(raw_data)) {
  df_wide <- as_tibble(raw_data$rows)
} else {
  df_wide <- as_tibble(raw_data)
}

colunas_identificadoras <- c("Ano", "IdCidade", "UF", "Município", "Cidade")
id_vars <- intersect(colunas_identificadoras, colnames(df_wide))

stopifnot("Variáveis de identificação críticas ausentes na resposta JSON" = 
            all(c("Ano", "IdCidade") %in% id_vars))

# 4. ADEQUANDO COM OS DADOS DO GEOBR
message("Buscando tabela de referência geográfica no geobr...")

# Baixa e prepara a tabela do geobr
muni_geo <- geobr::read_municipality(year = 2022, showProgress = FALSE) %>%
  sf::st_drop_geometry() %>%
  select(
    code_muni_7  = code_muni,    # Código IBGE com 7 dígitos (ex: 3304557)
    code_state,                  # Código do Estado (ex: 33)
    abbrev_state,                # UF (ex: "RJ")
    name_muni                    # Nome do Município
  ) %>%
  distinct(code_muni_7, .keep_all = TRUE) %>%
  mutate(
    # Extrai os primeiros 6 dígitos e garante 6 caracteres de texto
    code_muni_6 = sprintf("%06d", as.integer(substr(as.character(code_muni_7), 1, 6)))
  )

# Ajusta os nomes das colunas da Firjan e padroniza a chave de join
df_wide <- df_wide %>%
  rename_with(~ case_when(
    .x == "Município" ~ "name_muni",
    .x == "UF"        ~ "abbrev_state",
    TRUE              ~ .x
  )) %>%
  # Formata o IdCidade da Firjan como texto de 6 dígitos com zeros à esquerda
  mutate(code_muni_6 = sprintf("%06d", as.integer(IdCidade))) %>%
  left_join(
    muni_geo %>% select(code_muni_6, code_muni = code_muni_7, code_state),
    by = "code_muni_6"
  ) %>%
  select(-code_muni_6)

# Teste imediato de validação: verifica se code_muni foi preenchido
message(sprintf("Municípios pareados com sucesso: %d de %d linhas", 
                sum(!is.na(df_wide$code_muni)), 
                nrow(df_wide)))

# 5. TRANSFORMAÇÃO PARA FORMATO LONGO (PIVOT) E AJUSTE DE TIPAGEM
df_long <- df_wide %>%
  pivot_longer(
    cols = -all_of(id_vars_padrao),
    names_to = "Indicador_ou_Ranking",
    values_to = "Valor",
    values_transform = as.character
  ) %>%
  mutate(
    Ano        = as.integer(Ano),
    code_muni  = as.integer(code_muni),
    code_state = as.integer(code_state),
    Valor_clean = na_if(Valor, "-"),
    Valor      = as.numeric(Valor_clean),
    tipo       = if_else(startsWith(Indicador_ou_Ranking, "Ranking"), "ranking", "valor"),
    
    Indicador_ou_Ranking = Indicador_ou_Ranking %>%
      sub("^[0-9]+", "", .) %>%
      sub("^Valor", "", .) %>%
      sub("^Ranking", "", .) %>%
      tolower()
  ) %>%
  select(-Valor_clean)

message("\n--- Exemplo das primeiras linhas com as novas colunas ---")
print(head(df_long %>% select(any_of(c("Ano", "code_muni", "code_state", "abbrev_state", "name_muni", "Indicador_ou_Ranking", "Valor"))), 15))
message(sprintf("\nTotal de linhas extraídas: %s", format(nrow(df_long), big.mark = ".")))

# 6. EXPORTAÇÃO EM PARQUET DENTRO DE DIRETÓRIO TEMPORÁRIO
parquet_path <- file.path(tempdir(), "firjan_dados_longo_completo.parquet")

write_parquet(
  x = df_long,
  sink = parquet_path,
  compression = "snappy"
)

# 7. UPLOAD VIA PIGGYBACK E LIMPEZA
pb_upload(
  file = parquet_path,
  repo = "pedreirajr/av_imp_tz",
  tag  = "data",
  overwrite = TRUE
)

unlink(parquet_path)
message("Upload concluído com sucesso e arquivo local temporário removido.")
