library(httr2)
library(jsonlite)
library(tidyr)
library(dplyr)
library(readr)
library(arrow)
library(piggyback)

#0. Esse script se trata do armazenamento de dados do FIRJAN, em formato PARQUET, estão estruturados atualmente (09/26) numa JSON única. Segue a passo a passo. Há também uma versão em PYTHON (necessário a biblioteca PANDAS);

# 1. Download do arquivo JSON
url <- "https://firjan.com.br/data/files/E0/01/68/8E/F4D4991031B91689D8284EA8/dados-2025-final.json"

message("Baixando dados da Firjan...")

req <- request(url) %>%
  req_user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")

resp <- req_perform(req)
raw_data <- resp_body_json(resp, simplifyVector = TRUE)

# 2. Processar a estrutura do JSON para DataFrame
if (is.list(raw_data) && "rows" %in% names(raw_data)) {
  df_wide <- as_tibble(raw_data$rows)
} else {
  df_wide <- as_tibble(raw_data)
}

# 3. Definir colunas identificadoras presentes
colunas_identificadoras <- c("Ano", "IdCidade", "UF", "Município", "Cidade")
id_vars <- intersect(colunas_identificadoras, colnames(df_wide))

# 4. Transformar para formato longo (Pivot/Melt)
df_long <- df_wide %>%
  pivot_longer(
    cols = -all_of(id_vars),
    names_to = "Indicador_ou_Ranking",
    values_to = "Valor"
  )

message("\n--- Exemplo das primeiras linhas do formato longo ---")
print(head(df_long, 15))
message(sprintf("\nTotal de linhas extraídas: %s", format(nrow(df_long), big.mark = ".")))

# 5. Exportar para Parquet comprimido (usando Snappy por padrão)
parquet_filename <- "firjan_dados_longo_completo.parquet"

write_parquet(
  x = df_long,
  sink = parquet_filename,
  compression = "snappy")

message(sprintf("\nArquivo Parquet exportado com sucesso: %s", parquet_filename))

# 6. Upload do arquivo Parquet via piggyback
pb_upload(
  file = parquet_filename,
  overwrite = TRUE
)