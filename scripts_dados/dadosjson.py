import json
import urllib.request
import pandas as pd

# 1. URL do arquivo JSON da extraído da página Firjan no site: https://www.firjan.com.br/ifgf/
url = "https://firjan.com.br/data/files/E0/01/68/8E/F4D4991031B91689D8284EA8/dados-2025-final.json"
# Verifiquei que eles utilizam um único arquvio JSON para todos os anos, então não é necessário baixar vários arquivos. O arquivo contém dados de 2015 a 2025.

# Header para requisição HTTP
headers = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
}
req = urllib.request.Request(url, headers=headers)

print("Baixando dados da Firjan...")
with urllib.request.urlopen(req) as response:
    raw_data = json.loads(response.read().decode("utf-8"))

# 2. Carregar o DataFrame
if isinstance(raw_data, dict) and "rows" in raw_data:
    df_wide = pd.json_normalize(raw_data["rows"])
else:
    df_wide = pd.json_normalize(raw_data)

# 3. Definir APENAS as colunas que identificam a cidade/ano (Chaves Fixas)
colunas_identificadoras = ["Ano", "IdCidade", "UF", "Município", "Cidade"]

# Passo dado seguindo a lógica das colunas com ID. 
id_vars = [col for col in colunas_identificadoras if col in df_wide.columns]

# Valores, Rankings Estaduais e Rankings Nacionais vão para a coluna 'Valor'
value_vars = [col for col in df_wide.columns if col not in id_vars]

# 4. Transformar para Formato Longo (Melt/Unpivot)
df_long = pd.melt(
    df_wide,
    id_vars=id_vars,
    value_vars=value_vars,
    var_name="Indicador_ou_Ranking",
    value_name="Valor",
)

print("\n--- Exemplo das primeiras linhas do formato longo ---")
print(df_long.head(15))
print(f"\nTotal de linhas extraídas: {len(df_long):,}")

# 5. Exportar para CSV (Compatível com Excel / Power BI / SQL)
csv_filename = "firjan_dados_longo_completo.csv"
df_long.to_csv(csv_filename, index=False, encoding="utf-8-sig", sep=";")
print(f"\nArquivo CSV exportado com sucesso: {csv_filename}")
