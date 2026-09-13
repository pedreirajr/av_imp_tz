
pacotes <- c("rvest", "httr", "stringr")
faltando <- pacotes[!vapply(pacotes, requireNamespace, logical(1), quietly = TRUE)]
if (length(faltando)) install.packages(faltando, repos = "https://cloud.r-project.org")
invisible(lapply(pacotes, library, character.only = TRUE))


DIR_DATA_RAW <- "data-raw"
dir.create(DIR_DATA_RAW, recursive = TRUE, showWarnings = FALSE)

url_pagina <- "https://www.gov.br/anp/pt-br/centrais-de-conteudo/dados-abertos/vendas-de-derivados-de-petroleo-e-biocombustiveis"  # a URL da página do ANP

pagina <- read_html("https://www.gov.br/anp/pt-br/centrais-de-conteudo/dados-abertos/vendas-de-derivados-de-petroleo-e-biocombustiveis")

combustiveis_desejados <- c(
  "vendas-anuais-de-etanol-hidratado-por-municipio.csv",
  "vendas-anuais-de-gasolina-c-por-municipio.csv",
  "vendas-anuais-de-glp-por-municipio.csv",
  "vendas-anuais-de-oleo-diesel-por-municipio.csv"  
)


links <- pagina |> html_elements("a") |> html_attr("href")


links_selecionados <- links[
  !is.na(links) &
  stringr::str_detect(tolower(links), paste(combustiveis_desejados, collapse = "|"))
]

print(links_selecionados)

for (link in links_selecionados) {

  nome_arquivo <- stringr::str_replace(basename(link), "\\.csv$", "-raw.csv")  
  destino <- file.path(DIR_DATA_RAW, nome_arquivo)
  
  resp <- httr::GET(link, httr::write_disk(destino, overwrite = TRUE))
  
  if (httr::status_code(resp) == 200) {
    message("Salvo: ", nome_arquivo)
  } else {
    warning("Falha ao baixar (status ", httr::status_code(resp), "): ", link)
  }
}
