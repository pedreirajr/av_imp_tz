import pandas as pd
import os


def padronizar_colunas(df, mapa):
    colunas_nao_encontradas = [col for col in mapa if col not in df.columns]
    if colunas_nao_encontradas:
        print(f"Aviso: colunas esperadas no mapa não foram encontradas no df: {colunas_nao_encontradas}")
    return df.rename(columns=mapa)

def preencher_por_referencia(df, coluna_chave, colunas_para_preencher):
    for coluna in colunas_para_preencher:
        referencia = df.dropna(subset=[coluna]).drop_duplicates(subset=[coluna_chave])
        mapa = referencia.set_index(coluna_chave)[coluna]
        df[coluna] = df[coluna].fillna(df[coluna_chave].map(mapa))
    return df

mapa_padrao = {
    "ANO": "date",
    "GRANDE REGIÃO": "name_regi",
    "UF": "sigla_uf",
    "MUNICÍPIO": "name_muni",
    "CÓDIGO IBGE": "code_muni",
    "VENDAS": "vendas_litros"
}

mapa_glp = {
    "ANO": "date",
    "GRANDE REGIÃO": "name_regi",
    "UF": "sigla_uf",
    "MUNICÍPIO": "name_muni",
    "CÓDIGO IBGE": "code_muni",
    "P13": "vendas_vasilhames_p13_kg",
    "OUTROS": "vendas_vasilhames_outros_kg"
}

configuracoes = {
    "vendas-anuais-de-gasolina-c-por-municipio-raw.csv": mapa_padrao,
    "vendas-anuais-de-etanol-hidratado-por-municipio-raw.csv": mapa_padrao,
    "vendas-anuais-de-oleo-diesel-por-municipio-raw.csv": mapa_padrao,
    "vendas-anuais-de-glp-por-municipio-raw.csv": mapa_glp,
}

os.makedirs("dados_tratados", exist_ok=True)

for nome_arquivo, mapa in configuracoes.items():
    caminho_entrada = os.path.join("dados_brutos", nome_arquivo)
    df = pd.read_csv(caminho_entrada, sep=';', decimal= ',')
    
    df = padronizar_colunas(df, mapa)

    df["name_muni"] = df["name_muni"].str.strip()

    for coluna in ["name_muni", "sigla_uf", "name_regi"]:
        inconsistencias = df.dropna(subset=[coluna]).groupby("code_muni")[coluna].nunique()
        problemas = inconsistencias[inconsistencias > 1]
        if len(problemas) > 0:
            print(f"Inconsistências em '{coluna}': {len(problemas)} códigos com valores diferentes")

            # mostra alguns exemplos concretos, pra investigar a causa
            codigos_problematicos = problemas.index[:3]  # pega só os 3 primeiros pra não poluir o terminal
            for codigo in codigos_problematicos:
                exemplo = df[df["code_muni"] == codigo][[coluna]].drop_duplicates()
                print(f"  code_muni={codigo}:")
                print(exemplo.to_string(index=False))
        else:
            print(f"'{coluna}' está consistente por code_muni")
    

    df = preencher_por_referencia(
    df, 
    coluna_chave="code_muni", 
    colunas_para_preencher=["name_muni", "sigla_uf", "name_regi"]
    )
    
    caminho_saida = os.path.join("dados_tratados", nome_arquivo.replace("-raw", "-tratado"))
    df.to_csv(caminho_saida, index=False, sep=';')
    print(f"Tratado e salvo: {nome_arquivo}")



