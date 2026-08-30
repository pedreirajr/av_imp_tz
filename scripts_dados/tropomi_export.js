/**** TROPOMI -> médias mensais por município (NO2 troposférico e CO) ***********
 *
 * Cole este script no GEE Code Editor: https://code.earthengine.google.com
 *
 * 1) Ajuste ASSET para o ID do seu asset de municípios (shapefile do IBGE).
 * 2) Confira ID_PROP (coluna do código): "CD_MUN" no shapefile do IBGE.
 * 3) Clique em "Run". Vão aparecer 16 tarefas em "Tasks" (NO2 e CO, 2018-2025).
 * 4) Clique "RUN" em cada tarefa. Elas exportam CSVs para a pasta do Drive
 *    "tropomi_tarifazero".
 * 5) Baixe os CSVs do Drive para a pasta data-raw/gee/ do projeto e rode
 *    scripts_dados/03b_consolidar_gee.R.
 *
 * Saída de cada CSV: colunas code_muni, ano, mes, poluente, mean (mol/m²).
 *******************************************************************************/

// ==== CONFIGURAÇÃO ====
var ASSET   = 'projects/ee-thomasbarros/assets/BR_Municipios_2022';  // <-- AJUSTE
var ID_PROP = 'CD_MUN';      // coluna do código do município no asset (IBGE: CD_MUN)
var SCALE   = 1113.2;        // resolução (m) das grades L3 do S5P
var ANO_INI = 2018;          // TROPOMI começa em jul/2018
var ANO_FIM = 2025;

var municipios = ee.FeatureCollection(ASSET);

var PRODUTOS = [
  {nome: 'no2', col: 'COPERNICUS/S5P/OFFL/L3_NO2',
   band: 'tropospheric_NO2_column_number_density'},
  {nome: 'co',  col: 'COPERNICUS/S5P/OFFL/L3_CO',
   band: 'CO_column_number_density'}
];

// ==== UM EXPORT POR POLUENTE x ANO (tarefas menores = mais estáveis) ====
PRODUTOS.forEach(function (p) {
  for (var ano = ANO_INI; ano <= ANO_FIM; ano++) {
    var fcs = [];
    for (var mes = 1; mes <= 12; mes++) {
      if (ano === 2018 && mes < 7) continue;   // sem dado antes de jul/2018
      var ini = ee.Date.fromYMD(ano, mes, 1);
      var fim = ini.advance(1, 'month');
      var img = ee.ImageCollection(p.col).select(p.band)
                  .filterDate(ini, fim).mean();
      var red = img.reduceRegions({
        collection: municipios,
        reducer: ee.Reducer.mean(),
        scale: SCALE,
        tileScale: 4
      });
      var a = ano, m = mes, n = p.nome;   // fixa os valores nesta iteração
      red = red.map(function (f) {
        return f.set({code_muni: f.get(ID_PROP), ano: a, mes: m, poluente: n});
      });
      fcs.push(red);
    }
    var fc = ee.FeatureCollection(fcs).flatten();
    Export.table.toDrive({
      collection: fc,
      description: 'tropomi_' + p.nome + '_' + ano,
      folder: 'tropomi_tarifazero',
      fileFormat: 'CSV',
      selectors: ['code_muni', 'ano', 'mes', 'poluente', 'mean']
    });
  }
});

print('Pronto. Abra a aba "Tasks" e clique RUN em cada uma das 16 tarefas.');
