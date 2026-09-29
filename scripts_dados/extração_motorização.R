library(basedosdados)
library(arrow)
library(piggyback)



BILLING_ID  <- "seuprojeto"  # <-- troque pelo ID do SEU projeto no Google Cloud (billing)
ANO_INICIAL <- 2006            # recorte na ORIGEM (query): últimos 20 anos

REPO <- "pedreirajr/av_imp_tz" # repositório GitHub onde os assets são publicados
TAG  <- "data"                 # release "Dados do Projeto", onde a turma junta os dados

TABELA <- "`basedosdados.br_denatran_frota.municipio_tipo`"




tipos <- read_sql(
  query = sprintf("
SELECT DISTINCT tipo_veiculo
FROM %s
WHERE ano >= %d
  AND tipo_veiculo IS NOT NULL
  AND tipo_veiculo != ''
ORDER BY tipo_veiculo
", TABELA, ANO_INICIAL),
  billing_project_id = BILLING_ID
)$tipo_veiculo

message("  ", paste(tipos, collapse = ", "))


colunas <- paste(
  sprintf(
    "    SUM(CASE WHEN dados.tipo_veiculo = '%s' THEN dados.quantidade ELSE 0 END) AS %s",
    gsub("'", "\\\\'", tipos),                 
    gsub("[^a-z0-9_]", "_", tolower(tipos))    
  ),
  collapse = ",\n"
)

QUERY <- sprintf("
SELECT
    dados.id_municipio AS id_municipio,
    diretorio_id_municipio.nome AS id_municipio_nome,
    dados.sigla_uf     AS sigla_uf,
    dados.ano          AS ano,
    dados.mes          AS mes,
%s
FROM %s AS dados
LEFT JOIN (
    SELECT DISTINCT id_municipio, nome
    FROM `basedosdados.br_bd_diretorios_brasil.municipio`
) AS diretorio_id_municipio
    ON dados.id_municipio = diretorio_id_municipio.id_municipio
WHERE dados.ano >= %d
  AND dados.tipo_veiculo IS NOT NULL
  AND dados.tipo_veiculo != ''
GROUP BY id_municipio, id_municipio_nome, sigla_uf, ano, mes
", colunas, TABELA, ANO_INICIAL)



frota_wide <- read_sql(query = QUERY, billing_project_id = BILLING_ID)
message(sprintf("  Linhas baixadas: %s", format(nrow(frota_wide), big.mark = ".", decimal.mark = ",")))


frota_wide <- frota_wide[order(frota_wide$id_municipio, frota_wide$ano, frota_wide$mes), ]


if ("automovel" %in% names(frota_wide)) {
  message(sprintf("Soma total de automóveis: %s",
                   format(sum(frota_wide$automovel), big.mark = ".", decimal.mark = ",", scientific = FALSE)))
}
message(sprintf("Painel final: %s linhas, %d colunas",
                 format(nrow(frota_wide), big.mark = ".", decimal.mark = ","), ncol(frota_wide)))


arquivo_saida <- "frota_mensal_municipio.parquet"
write_parquet(frota_wide, arquivo_saida)
message(sprintf("Arquivo salvo: %s (%s linhas)",
                 arquivo_saida, format(nrow(frota_wide), big.mark = ".", decimal.mark = ",")))



#publicação no release via piggyback 
releases <- pb_releases(repo = REPO)
if (!(TAG %in% releases$tag_name)) {
  pb_new_release(repo = REPO, tag = TAG)
}
pb_upload(file = arquivo_saida, repo = REPO, tag = TAG, overwrite = TRUE)
message(sprintf("Publicado em https://github.com/%s/releases/tag/%s", REPO, TAG))
