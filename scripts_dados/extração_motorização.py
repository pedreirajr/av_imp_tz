import basedosdados as bd
import pandas as pd

BILLING_ID  = "ictarifazero"  # <-- ID do projeto no Google Cloud (billing)
ANO_INICIAL = 2006               # recorte na ORIGEM (query): traz de 2006 em diante
ANO_CORTE   = 2010               # recorte ADICIONAL para um segundo arquivo


QUERY = f"""
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
WHERE dados.ano >= {ANO_INICIAL}
"""


def main():
    print("Baixando dados do BigQuery (pode levar alguns minutos)...")
    frota_long = bd.read_sql(query=QUERY, billing_project_id=BILLING_ID)
    print(f"  Linhas baixadas: {len(frota_long):,}")

    # -----------------------------------------------------------------------
    # 3. Limpeza: remover registros sem tipo de veículo definido
    # -----------------------------------------------------------------------
    frota_long = frota_long[
        frota_long["tipo_veiculo"].notna() & (frota_long["tipo_veiculo"] != "")
    ].copy()
    frota_long["quantidade"] = pd.to_numeric(frota_long["quantidade"], errors="coerce")

    print("Tipos de veículo encontrados:")
    print("  " + ", ".join(sorted(frota_long["tipo_veiculo"].unique())))

    # -----------------------------------------------------------------------
    # 4. Pivotar: uma linha por município x mês, tipos em colunas
    #    (pivot_table com aggfunc='sum' devolve colunas numéricas planas,
    #    evitando o problema de list-column que ocorre no pivot do R)
    # -----------------------------------------------------------------------
    frota_wide = frota_long.pivot_table(
        index=["id_municipio", "id_municipio_nome", "sigla_uf", "ano", "mes"],
        columns="tipo_veiculo",
        values="quantidade",
        aggfunc="sum",
        fill_value=0,
    ).reset_index()
    frota_wide.columns.name = None
    frota_wide = frota_wide.sort_values(["id_municipio", "ano", "mes"])

    # checagem de integridade
    if "automovel" in frota_wide.columns:
        print(f"Soma total de automóveis: {frota_wide['automovel'].sum():,.0f}")
    print(f"Painel final: {len(frota_wide):,} linhas, {len(frota_wide.columns)} colunas")

    # -----------------------------------------------------------------------
    # 5. Salvar (série completa + recorte a partir de ANO_CORTE)
    #    encoding utf-8-sig garante acentos corretos no Excel.
    # -----------------------------------------------------------------------
    frota_wide.to_csv("frota_mensal_municipio.csv", index=False, encoding="utf-8-sig")

    frota_corte = frota_wide[frota_wide["ano"] >= ANO_CORTE].copy()
    frota_corte.to_csv(
        f"frota_mensal_municipio_{ANO_CORTE}.csv", index=False, encoding="utf-8-sig"
    )

    print(f"Arquivos salvos:")
    print(f"  frota_mensal_municipio.csv        ({len(frota_wide):,} linhas)")
    print(f"  frota_mensal_municipio_{ANO_CORTE}.csv   ({len(frota_corte):,} linhas)")


if __name__ == "__main__":
    main()