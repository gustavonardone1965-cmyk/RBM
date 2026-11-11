# Recomendador RBM de Compras — Consultnet SRL

Recomendador de productos basado en una Máquina de Boltzmann Restringida (RBM) para reconfigurar pedidos de clientes internos y externos: reposición, upselling, cross-selling y novedades, más detección de pedidos atípicos. Los datos incluidos son **ficticios** y sirven de modelo para reemplazarlos por los reales.

## Uso diario: sólo el HTML
Abrir `www/index.html` en el navegador (Chrome o Edge). No hace falta instalar nada: el motor RBM, los datos de ejemplo y un modelo ya entrenado están dentro del archivo.

- **Ventana de análisis** (arriba): elegir Desde y Hasta y tocar “Aplicar ventana”. El modelo se reentrena con los pedidos de ese rango.
- **Armar pedido** trabaja con un cliente, con un grupo o con toda la cartera. Los filtros Tipo de cliente y Segmento tienen la opción “Todos” y se combinan; “Armar grupo” toma los clientes de esa segmentación y “Elegir clientes a mano” permite tildarlos uno por uno. En grupo, las sugerencias se suman por producto y “Aplicar a los N” reconfigura todos esos pedidos de una vez.
- **Guardar cambios** (arriba): conserva en ese navegador los datos cargados, la ventana, el modelo y los pedidos reconfigurados.
- **Enviar a PDF**: en “Armar pedido” emite la recomendación en detalle del cliente; en “Oportunidades”, el plan de la cartera.
- **Datos**: carga de CSV o Excel de pedidos, clientes y productos, altas manuales, control de calidad y **respaldo** (un archivo para pasar el trabajo a otra computadora).
- **Reemplazar toda la base** (en Datos): para pasar de los datos de ejemplo a los reales, o corregir datos ya cargados, eligiendo las tres tablas completas.
- **Manual de uso** (última pestaña): guía detallada de cada función, con índice y descarga en PDF.
- Sin internet sigue funcionando: lee CSV, descarga en CSV y el PDF sale por la impresión del navegador.

## Motor en R (opcional)
Mismo algoritmo y mismas reglas, para auditar o programar corridas. Requiere R instalado; no usa paquetes.

- `EJECUTAR_R.bat` (o `Rscript R/ejecutar.R --desde=2025-07-01 --hasta=2026-06-30`): incorpora lo que haya en `datos/entrada/`, valida, entrena o actualiza y deja el plan de oportunidades y los pedidos atípicos en `salidas/`. Opciones: `--completo`, `--afinar`.
- `Rscript R/pruebas.R`: batería de pruebas automáticas.

## Estructura
| Carpeta / archivo | Contenido |
|---|---|
| `www/index.html` | Tablero autónomo con el motor RBM en JavaScript |
| `datos/clientes.csv`, `productos.csv`, `pedidos.csv` | Las 3 tablas (UTF-8, separador coma) |
| `datos/Base_inicial_RBM.xlsx` | Diccionario de datos, las 3 tablas y la matriz cliente × producto con fórmulas |
| `R/rbm_core.R` | RBM en R base: CD-k, momentum, weight decay, expansión de unidades |
| `R/pipeline.R` | Ventana, matriz, conjunto de RBM, evaluación, recomendación con motivos, atípicos, validación, ingesta |
| `R/ejecutar.R`, `R/pruebas.R` | Corrida completa y pruebas |
| `modelo/`, `salidas/` | Modelo entrenado en R, historial y resultados de la última corrida |
| `PROMPT_MAESTRO.md` | Prompt que reconstruye todo el sistema |

## Cómo funciona el modelo
- Visibles: un 1 por cada SKU que el cliente compró en ventanas móviles de 6 meses (paso de 3 meses), más unidades de contexto de tipo y segmento.
- Conjunto de 3 RBM de 8 unidades ocultas; se promedia la probabilidad. “Afinar automáticamente” prueba 4, 8, 16 y 24.
- Recomendación: se reconstruye el perfil del cliente (últimos 12 meses) más el pedido actual. Upselling = versión Premium o `sku_superior` de la misma subfamilia; cross-selling = subfamilias que el cliente todavía no cubre; cada sugerencia indica por qué productos del cliente se propone.
- Atípicos: productos del pedido con probabilidad menor al umbral (5 %) para ese cliente, o cantidades más de 3 desvíos sobre su historia.
- Evaluación: se oculta el 20 % de los productos de cada cliente y se mide si el modelo los recupera, contra “lo más vendido del segmento”.
