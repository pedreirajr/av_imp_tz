# Publica os arquivos Parquet como assets de uma Release do GitHub.
# Execute com o diretorio de trabalho em scripts_dados/Dados_da_ANP/, depois da conversao:
# source("04_publicar_combustiveis_parquet.R", encoding = "UTF-8")

if (!requireNamespace("piggyback", quietly = TRUE)) {
  install.packages("piggyback", repos = "https://cloud.r-project.org")
}

REPOSITORIO <- "pedreirajr/av_imp_tz"
TAG_RELEASE <- "data"
DIR_PARQUET <- "parquet"

# Um token nao deve ser escrito neste script. Antes de executar, configure-o
# somente na sua sessao R com Sys.setenv(GITHUB_PAT = "seu_token").
if (!nzchar(Sys.getenv("GITHUB_PAT"))) {
  stop(
    "GITHUB_PAT nao esta configurado.\n",
    "No console, execute: Sys.setenv(GITHUB_PAT = \"seu_token\")\n",
    "Depois execute este script novamente."
  )
}

arquivos_parquet <- list.files(
  DIR_PARQUET,
  pattern = "\\.parquet$",
  full.names = TRUE
)

if (length(arquivos_parquet) != 4L) {
  stop(
    "Foram encontrados ", length(arquivos_parquet), " arquivos Parquet em ", DIR_PARQUET,
    ". Execute primeiro converter_combustiveis_parquet.R."
  )
}

releases <- piggyback::pb_releases(repo = REPOSITORIO)
if (!TAG_RELEASE %in% releases$tag_name) {
  piggyback::pb_release_create(
    repo = REPOSITORIO,
    tag = TAG_RELEASE,
    name = "Dados do projeto",
    body = "Arquivos tratados da ANP em formato Parquet."
  )
}

for (arquivo in arquivos_parquet) {
  piggyback::pb_upload(
    file = arquivo,
    repo = REPOSITORIO,
    tag = TAG_RELEASE,
    overwrite = TRUE,
    show_progress = TRUE
  )
}

message(
  "Publicacao concluida. Os arquivos Parquet foram enviados para a Release '",
  TAG_RELEASE, "' de ", REPOSITORIO, "."
)
