# Recomendador RBM de Compras — Consultnet SRL

Recomendador de productos basado en una Máquina de Boltzmann Restringida (RBM) para reconfigurar pedidos de clientes internos y externos: reposición, upselling, cross-selling y novedades, más detección de pedidos atípicos. Los datos incluidos son **ficticios** y sirven de modelo para reemplazarlos por los reales.

## Uso diario: sólo el HTML
Abrir `www/index.html` en el navegador (Chrome o Edge). No hace falta instalar nada ni usar R: el motor RBM, los datos de ejemplo y un modelo ya entrenado están dentro del archivo, y todo funciona sin conexión a internet.

- **La base son tres Excel**: `datos/productos.xlsx`, `datos/clientes.xlsx` y `datos/pedidos.xlsx` (una hoja cada uno). Se descargan del tablero, se editan en Excel y se vuelven a cargar con “Reemplazar toda la base”, en la sección Datos.
- **Ventana de análisis** (arriba): elegir Desde y Hasta y tocar “Aplicar ventana”. El modelo se reentrena con los pedidos de ese rango.
- **Umbral de recomendación** (sección Modelo): sólo se proponen productos con esa afinidad o más. Viene en 70%, se mueve entre 50% y 100% de a 5 puntos y se aplica al instante, sin reentrenar. No rige para reposición ni novedades.
- **Guardar cambios** (arriba): conserva en ese navegador la base, la ventana, el modelo y los pedidos reconfigurados.
- **Armar pedido** trabaja con un cliente, con un grupo o con toda la cartera. Los filtros Tipo de cliente y Segmento tienen la opción “Todos” y se combinan; “Armar grupo” toma los clientes de esa segmentación y “Elegir clientes a mano” permite tildarlos uno por uno.
- **Enviar a PDF**: la recomendación en detalle de un cliente, de un grupo, el plan de la cartera o el manual.
- **Manual de uso** (última pestaña): guía detallada de cada función, con índice y descarga en PDF.

## Motor en R (complementario, no hace falta para operar)
Mismo algoritmo y mismas reglas que el HTML, para auditar los resultados o programar corridas. Lee los mismos tres Excel. Requiere R y los paquetes `readxl` y `writexl` (`install.packages(c("readxl","writexl"))`).

- `EJECUTAR_R.bat`, o `Rscript R/ejecutar.R --desde=2025-07-01 --hasta=2026-06-30 --umbral=0.7`: incorpora lo que haya en `datos/entrada/`, valida, entrena o actualiza y deja el plan de oportunidades y los pedidos atípicos en `salidas/`, en Excel. Opciones: `--completo`, `--afinar`.
- `Rscript R/pruebas.R`: batería de pruebas automáticas.

## Estructura
| Carpeta / archivo | Contenido |
|---|---|
| `www/index.html` | Tablero autónomo con el motor RBM, los datos de ejemplo y el manual |
| `datos/productos.xlsx`, `clientes.xlsx`, `pedidos.xlsx` | Las tres bases |
| `datos/Base_inicial_RBM.xlsx` | Diccionario de datos, las tres tablas y la matriz cliente × producto con fórmulas |
| `R/rbm_core.R` | RBM en R base: CD-k, momentum, weight decay, expansión de unidades |
| `R/pipeline.R` | Lectura de los Excel, ventana, matriz, conjunto de RBM, evaluación, recomendación con umbral y motivos, atípicos, validación, ingesta |
| `R/ejecutar.R`, `R/pruebas.R` | Corrida completa y pruebas |
| `modelo/`, `salidas/` | Modelo entrenado en R, historial y resultados de la última corrida |
| `PROMPT_MAESTRO.md` | Prompt que reconstruye todo el sistema |

## Cómo funciona el modelo
- Visibles: un 1 por cada SKU que el cliente compró en ventanas móviles de 6 meses (paso de 3 meses), más unidades de contexto de tipo y segmento.
- Conjunto de 3 RBM de 8 unidades ocultas; se promedia la probabilidad. “Afinar automáticamente” prueba 4, 8, 16 y 24.
- Recomendación: se reconstruye el perfil del cliente (últimos 12 meses) más el pedido actual, y se proponen sólo los productos que superan el umbral. Upselling = versión Premium o `sku_superior` de la misma subfamilia; cross-selling = subfamilias que el cliente todavía no cubre; cada sugerencia indica por qué productos del cliente se propone.
- Atípicos: productos del pedido con probabilidad menor al umbral de atípico (5%) para ese cliente, o cantidades más de 3 desvíos sobre su historia.
- Evaluación: se oculta el 20% de los productos de cada cliente y se mide si el modelo los recupera, contra “lo más vendido del segmento”.
