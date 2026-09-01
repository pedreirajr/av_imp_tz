
from bs4 import BeautifulSoup
import requests 
import os


site = requests.get('https://www.gov.br/anp/pt-br/centrais-de-conteudo/dados-abertos/vendas-de-derivados-de-petroleo-e-biocombustiveis')

soup = BeautifulSoup(site.content, "html.parser")

combustiveis_desejados = [
    "vendas-anuais-de-etanol-hidratado-por-municipio.csv", 
    "vendas-anuais-de-gasolina-c-por-municipio.csv", 
    "vendas-anuais-de-glp-por-municipio.csv", 
    "vendas-anuais-de-oleo-diesel-por-municipio.csv"
]

links_selecionados = []



for link in soup.find_all('a'):
    Links_donwload =  link.get('href')
    if Links_donwload:   
        Links_donwload_lower = Links_donwload.lower()
        if any(termo in Links_donwload_lower for termo in combustiveis_desejados):
            links_selecionados.append(Links_donwload)

pasta_destino = "dados_brutos"

os.makedirs(pasta_destino, exist_ok=True)

for link in links_selecionados:
    resposta = requests.get(link)

    nome_arquivo = link.split('/')[-1].replace('.csv','-raw.csv')

    caminho_completo = os.path.join(pasta_destino, nome_arquivo)

    with open(caminho_completo, 'wb') as arquivo:
        arquivo.write(resposta.content)

    print(f"Salvo: {nome_arquivo}")
    




        




