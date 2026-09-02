library(basedosdados)
library(dplyr)
library(tidyr)
library(readr)
library(piggyback)

# -----------------------------------------------------------------------
# 1. Configuração
# -----------------------------------------------------------------------
BILLING_ID  <- "ictarifazero"  # ID do projeto no Google Cloud (billing)
ANO_INICIAL <- 2006            # recorte na ORIGEM (query): últimos 20 anos

REPO <- "pedreirajr/av_imp_tz" # repositório GitHub onde os assets são publicados
TAG  <- "dados-motorizacao"    # tag da release usada pelo piggyback

# Autenticação do piggyback: crie um arquivo `.Renviron` na raiz do projeto
# (ele já está no .gitignore, então fica só na sua máquina) com a linha:
#   GITHUB_PAT=seu_token_aqui
# gerando o token em https://github.com/settings/tokens (escopo "repo").
# Depois de criar/editar o .Renviron, reinicie a sessão do R.

# -----------------------------------------------------------------------
# 2. Query
# -----------------------------------------------------------------------
QUERY <- sprintf("
SELECT
    dados.ano          AS ano,
    dados.mes          AS mes,
    dados.sigla_uf     AS sigla_uf,
    dados.id_municipio AS id_municipio,
    diretorio_id_municipio.nome AS id_municipio_nome,
    dados.tipo_veiculo AS tipo_veiculo,
    dados.quantidade   AS quantidade
FROM `basedosdados.br_denatran_frota.municipio_tipo` AS dados
LEFT JOIN (
    SELECT DISTINCT id_municipio, nome
    FROM `basedosdados.br_bd_diretorios_brasil.municipio`
) AS diretorio_id_municipio
    ON dados.id_municipio = diretorio_id_municipio.id_municipio
WHERE dados.ano >= %d
", ANO_INICIAL)


message("Baixando dados do BigQuery (pode levar alguns minutos)...")
frota_long <- read_sql(query = QUERY, billing_project_id = BILLING_ID)
message(sprintf("  Linhas baixadas: %s", format(nrow(frota_long), big.mark = ".")))

# -----------------------------------------------------------------------
# 4. Limpeza: remover registros sem tipo de veículo definido
# -----------------------------------------------------------------------
frota_long <- frota_long %>%
  filter(!is.na(tipo_veiculo) & tipo_veiculo != "") %>%
  mutate(quantidade = suppressWarnings(as.numeric(quantidade)))

message("Tipos de veículo encontrados:")
message("  ", paste(sort(unique(frota_long$tipo_veiculo)), collapse = ", "))

# -----------------------------------------------------------------------
# 5. Pivotar: uma linha por município x mês, tipos em colunas
#    (soma via group_by antes do pivot_wider evita o problema de
#    list-column quando há combinações duplicadas de chave x tipo)
# -----------------------------------------------------------------------
frota_wide <- frota_long %>%
  group_by(id_municipio, id_municipio_nome, sigla_uf, ano, mes, tipo_veiculo) %>%
  summarise(quantidade = sum(quantidade, na.rm = TRUE), .groups = "drop") %>%
  pivot_wider(names_from = tipo_veiculo, values_from = quantidade, values_fill = 0) %>%
  arrange(id_municipio, ano, mes)

# checagem de integridade
if ("automovel" %in% names(frota_wide)) {
  message(sprintf("Soma total de automóveis: %s",
                   format(sum(frota_wide$automovel), big.mark = ".", scientific = FALSE)))
}
message(sprintf("Painel final: %s linhas, %d colunas",
                 format(nrow(frota_wide), big.mark = "."), ncol(frota_wide)))


arquivo_saida <- "frota_mensal_municipio.csv"
write_excel_csv(frota_wide, arquivo_saida)
message(sprintf("Arquivo salvo: %s (%s linhas)",
                 arquivo_saida, format(nrow(frota_wide), big.mark = ".")))



releases <- pb_releases(repo = REPO)
if (!(TAG %in% releases$tag_name)) {
  pb_new_release(repo = REPO, tag = TAG)
}
pb_upload(file = arquivo_saida, repo = REPO, tag = TAG)
message(sprintf("Publicado em https://github.com/%s/releases/tag/%s", REPO, TAG))
