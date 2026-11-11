# Prompt maestro — Recomendador RBM de Compras

Versión consolidada del 11 de noviembre de 2026. Reemplaza a las anteriores: incluye el motor en conjunto, la ventana de análisis, el guardado, los PDF, el trabajo por grupo de clientes, la segmentación con la opción “Todos”, el reemplazo completo de la base y el manual de uso dentro del tablero.

Copiar todo lo que sigue en un asistente que pueda ejecutar código y generar archivos. Los valores entre corchetes se pueden cambiar antes de pegarlo.

---

## Rol y objetivo

Sos un especialista en machine learning aplicado a supply chain, con dominio de R, JavaScript y diseño de interfaces. Tenés que construir de punta a punta un **recomendador de productos para el área de Compras** de [EcoClean, empresa de servicios y artículos de limpieza con sede en Córdoba, Argentina], basado en una **Máquina de Boltzmann Restringida (RBM)**.

Objetivo de negocio: cuando entra un pedido de un cliente interno (un contrato o sitio propio que pide insumos a Compras central) o externo (un cliente que compra artículos), Compras debe poder **reconfigurarlo** para lograr upselling y cross-selling, en clientes existentes y en clientes nuevos, de a un cliente, por grupo o para toda la cartera, y detectar pedidos atípicos antes de comprar.

Quien lo usa todos los días es personal de Compras que **no sabe programar ni usar R**. El producto principal es **un único archivo HTML autónomo que hace todo en el navegador**: entrena, recomienda, guarda y emite los informes. R queda como motor espejo, opcional, para auditar y para corridas programadas.

Idioma de todo lo visible: español rioplatense, claro y sin jerga técnica en la interfaz. Moneda: pesos argentinos con formato `$ 1.234.567`. No inventes resultados: todo número que informes tiene que salir de una corrida real.

## Entregables

1. `www/index.html`: tablero autónomo con el motor RBM en JavaScript, los datos de ejemplo y un modelo preentrenado embebidos (abre al instante, sin entrenar).
2. `datos/clientes.csv`, `datos/productos.csv`, `datos/pedidos.csv` (UTF-8, separador coma) y `datos/Base_inicial_RBM.xlsx` con diccionario de datos, las tres tablas y una hoja con la matriz cliente × producto calculada con fórmulas.
3. `R/rbm_core.R` (la RBM), `R/pipeline.R` (lógica de negocio), `R/ejecutar.R` (corrida completa por línea de comandos), `R/pruebas.R` (pruebas automáticas) y un `.bat` para Windows.
4. `LEEME.md` con uso, estructura y funcionamiento.

## 1. Bases de datos de entrada

Tres tablas. Los nombres de columna son exactos.

**clientes**: `id_cliente` (clave), `razon_social`, `tipo` (Interno / Externo), `segmento`, `provincia`, `pais`, `tamano` (Chico / Mediano / Grande), `fecha_alta` (AAAA-MM-DD).

**productos**: `sku` (clave), `nombre`, `familia`, `subfamilia`, `unidad`, `gama` (Estándar / Premium), `tipo_item` (C = consumible, E = equipo), `precio_lista`, `sku_superior` (SKU de la versión superior; puede ir vacío), `fecha_alta`, `activo` (Sí / No).

**pedidos** (una fila por línea): `id_pedido`, `fecha` (AAAA-MM-DD), `id_cliente`, `sku`, `cantidad`, `precio_unitario`, `canal`. Clave: `id_pedido` + `sku`.

La `subfamilia` agrupa productos sustitutos y es lo que separa upselling (misma subfamilia) de cross-selling (otra subfamilia). `tipo` y `segmento` son además unidades de contexto del modelo.

**Control de calidad** (calcularlo y mostrarlo siempre). Errores: claves repetidas; líneas con cliente o SKU inexistente; fecha inválida; cantidad cero o negativa; `sku_superior` inexistente; cliente sin tipo o sin segmento; ventana sin pedidos. Avisos: productos sin precio; clientes sin pedidos en la ventana; productos sin ventas en la ventana; ventana de menos de 6 meses.

**Carga tolerante**: los encabezados se normalizan (sin acentos, minúsculas, espacios a guion bajo) y se aceptan sinónimos de ERP: código / artículo → `sku`; descripción / producto → `nombre`; sub familia → `subfamilia`; precio → `precio_lista`; pedido / nro pedido / orden → `id_pedido`; cliente / cod cliente → `id_cliente`; cant → `cantidad`; rubro → `segmento`. Un sinónimo nunca pisa una columna que ya viene con su nombre correcto. Cada fila rechazada se informa con su número y el motivo; las repetidas se ignoran.

### Datos de ejemplo a generar (ficticios, reproducibles con semilla fija)

- **Catálogo**: [82] productos en 11 familias: químicos de limpieza, químicos industriales, papelería sanitaria, dispensadores, higiene de manos, bolsas y residuos, utensilios, equipos, repuestos y accesorios, elementos de protección personal, ambientación. La mayoría de las subfamilias tiene un par Estándar / Premium enlazado por `sku_superior`. Tres productos con alta en los últimos 90 días (novedades). Precios de lista plausibles para Argentina.
- **Clientes**: [89], internos y externos, en 8 segmentos: Alimenticia, Salud, Oficinas, Público/Municipal, Educación, Industrial, Hotelería, Consorcios. Incluir 6 altas recientes, algunas en Paraguay, Uruguay y Chile. La provincia tiene que ser coherente con el nombre cuando el nombre la indica.
- **Pedidos**: 24 meses (noviembre 2024 a octubre 2026); frecuencia mensual para internos y de 30 a 60 días para externos; cerca de [1.700] pedidos y [22.000] líneas; numeración cronológica; precios que suben mes a mes.
- **Estructura latente obligatoria**: además del segmento, cada cliente tiene “rasgos operativos” ocultos que atraviesan segmentos (Mecanizado, Sustentable, Cocina, Imagen, Sanitario, Exterior). Cada rasgo activa un conjunto de 7 a 9 productos con probabilidad 0,8 y su probabilidad depende del segmento. El surtido de cada cliente es incompleto a propósito (esas faltas son las oportunidades). Cada cliente tiene una afinidad por la gama Premium. Hay dependencias (quien tiene un dispensador compra su consumible; quien tiene un equipo compra su repuesto). Sin esta estructura la RBM no puede superar a “lo más vendido del segmento”.
- **Pedidos atípicos inyectados**: 16 pedidos con dos productos impropios del segmento del cliente, listados en un archivo de control para medir la detección.
- El generador no puede depender del orden de iteración de conjuntos: dos corridas deben dar archivos idénticos.

## 2. El modelo

**RBM Bernoulli–Bernoulli implementada desde cero**, sin librerías de deep learning, con el mismo algoritmo en JavaScript y en R.

- **Unidades visibles**: una por SKU más unidades de contexto, una por cada tipo de cliente (`TIPO:x`) y una por cada segmento (`SEG:x`). Las de contexto resuelven el arranque en frío de clientes nuevos.
- **Ventana de análisis**: un rango Desde / Hasta inclusivo, opcional. Todo (filas de entrenamiento, perfil, último pedido, evaluación, atípicos) usa sólo los pedidos de ese rango. La “última fecha” es la del último pedido dentro del rango.
- **Filas de entrenamiento**: una por cliente y por ventana móvil de 6 meses, con paso de 3 meses y hasta 9 cortes hacia atrás desde la última fecha, sin pasar del inicio de la ventana de análisis; 1 si el cliente compró el SKU en esa ventana móvil. Las restas de meses respetan el fin de mes (31/10 menos 6 meses = 30/04).
- **Entrenamiento**: Contrastive Divergence CD-1; estado oculto muestreado en la fase positiva y probabilidades en la reconstrucción; minilotes de 16; tasa 0,05; momentum 0,5 las primeras 5 épocas y 0,9 después; weight decay 2e-4; 300 épocas; pesos iniciales N(0; 0,01); sesgo visible inicial igual al logit de la frecuencia de la columna (acotada entre 0,01 y 0,99); semilla fija y generador propio para que sea reproducible.
- **Conjunto**: 3 RBM de 8 unidades ocultas con semillas distintas; el puntaje es el promedio de sus probabilidades (mejora la precisión y la estabilidad frente a una sola RBM).
- **Puntaje**: vector con los SKU del perfil del cliente (lo comprado en los últimos 12 meses de la ventana), más los del pedido en curso, más su tipo y segmento; se calcula p(h|v) y luego p(v|h) por campo medio. Esa probabilidad es la “afinidad”.
- **Evaluación**: ocultar al azar el 20 % de los productos de cada cliente con 5 o más (mínimo 1), entrenar sin ellos y medir acierto top 5 (al menos un oculto entre los 5 primeros) y cobertura top 10. Línea de base: lo más vendido del segmento. Mostrar siempre las dos cifras juntas; si ningún cliente tiene 5 productos, informar “sin evaluación”.
- **Afinado automático**: probar 4, 8, 16 y 24 unidades ocultas y quedarse con la mejor.
- **Actualización en caliente**: ante datos nuevos, agregar unidades visibles para productos, tipos o segmentos nuevos (pesos N(0; 0,01), sesgo por frecuencia) y seguir entrenando 120 épocas con la mitad de la tasa. Si cambia la arquitectura (unidades ocultas o cantidad de modelos) o la ventana de análisis, reentrenar completo.

## 3. Reglas de recomendación

Para un cliente y un pedido en curso, cuatro listas (hasta 6 ítems; novedades hasta 3), sin repetir productos entre listas y sin sugerir nada que el cliente ya compre o que ya esté en el pedido:

1. **Reposición**: productos presentes en 30 % o más de sus pedidos del período que faltan en el pedido actual, por frecuencia.
2. **Upselling**: para cada producto que usa, su `sku_superior` o un Premium de la misma subfamilia, activo y más caro. Informar a cuál reemplaza y el importe incremental (diferencia de precio por cantidad típica).
3. **Cross-selling**: productos activos de subfamilias que el cliente todavía no cubre, por afinidad, uno por subfamilia. Importe = precio de lista por cantidad típica.
4. **Novedades**: productos con alta en los últimos 120 días que no estén ya en upselling, por afinidad; si la afinidad es menor a 5 %, rotular “todavía sin historial: ofrecer como lanzamiento”.

**Cantidad típica**: mediana de la cantidad pedida de ese SKU en el segmento (mínimo 1). **Motivo** de cada sugerencia: los dos productos del cliente cuya ausencia más baja la probabilidad del candidato (se recalcula el puntaje quitándolos de a uno; caída mínima 0,01). Se muestra como “Porque compra: …”.

**Aceptar una sugerencia**: en upselling la línea nueva reemplaza a la del producto base conservando su cantidad (si el base no está en el pedido, se agrega); en cross-selling se agrega con la cantidad típica; en reposición y novedades, con cantidad 1. La regla es la misma para un cliente y para un grupo.

**Pedidos atípicos**: para cada pedido del período del perfil, puntuar con el perfil del cliente sin ese pedido; marcar productos con probabilidad menor al umbral (5 % por defecto, ajustable) que no estén en sus otros pedidos y no sean novedades; marcar cantidades con z mayor a 3 sobre el logaritmo de la historia cliente–SKU. Ordenar por rareza (promedio de −log p).

**Plan de oportunidades**: las mejores 3 de upselling y 3 de cross-selling para cada cliente de la cartera, con importe incremental y motivo.

## 4. El tablero HTML (producto principal)

Un solo archivo, sin servidor. Librerías sólo por `<script>` desde cdnjs con versión fija: SheetJS 0.18.5 (Excel) y jsPDF 2.5.1 (PDF). **Todo tiene que seguir funcionando sin internet**: lector CSV propio (coma o punto y coma, comillas, BOM); descargas en CSV si no cargó SheetJS; impresión del navegador si no cargó jsPDF. Diseño sobrio para un escritorio de Compras, con modo claro y oscuro, usable en celular sin desborde horizontal, foco visible por teclado, y mensajes de error dentro de la página (no ventanas emergentes). Colores con significado fijo: amarillo = upselling, verde = cross-selling, gris azulado = reposición, violeta = novedades, rojo = atípico. El entrenamiento muestra un velo con texto de avance y, si falla, no reemplaza el modelo vigente.

### Franja superior, visible en todas las secciones

- **Ventana de análisis**: fechas Desde y Hasta (por defecto, todo el historial), botón “Aplicar ventana” y botón “Todo el historial”. Al aplicar se reentrena completo y se recalcula todo. Validar que Desde no sea posterior a Hasta y que haya pedidos en el rango. Al cambiar la ventana se descartan los pedidos reconfigurados sin guardar, porque cambia el último pedido de cada cliente.
- **Guardar cambios**: persiste en el navegador (IndexedDB) los datos cargados, la ventana, los parámetros, el modelo, el historial y **todos** los pedidos reconfigurados. Indicador: “Sin cambios”, “Cambios sin guardar” o “Guardado el …”. Avisar antes de cerrar con cambios sin guardar. Al reabrir se restaura todo; si el navegador no permite guardar, decirlo y remitir al respaldo.

### Sección Armar pedido

**Segmentación** (primera fila):

- Desplegable **Tipo de cliente** con las opciones **Todos**, Interno, Externo, y desplegable **Segmento** con **Todos** y cada segmento. “Todos” es la opción inicial en los dos.
- Los dos filtros se combinan: Todos + Todos es la cartera completa; un tipo con segmento Todos trae todos los segmentos de ese tipo; un segmento con tipo Todos trae internos y externos de ese segmento.
- Botón principal **Armar grupo** con el texto dinámico “Armar grupo con estos N clientes” (o “con los N clientes” si es toda la cartera; deshabilitado si no hay ninguno; si hay uno solo, abre ese cliente).
- Botón **Elegir clientes a mano**: diálogo con búsqueda, los mismos filtros de tipo y segmento (también con “Todos”, y arrancan con la segmentación de la pantalla), casillas, “Marcar los que se ven”, “Quitar los que se ven” y contador de elegidos.
- Botón **Todos los clientes**: vuelve los dos filtros a “Todos” y arma el grupo con la cartera.

**Un cliente** (segunda fila): buscador por nombre o código, filtrado por la segmentación, con el rótulo “Cliente (N de M con este tipo y segmento)”. Botón “Empezar con cliente nuevo”: exige un tipo y un segmento concretos; con “Todos” muestra un aviso que lo explica.

**Vista de un cliente**: ticket editable (cantidades, quitar, agregar producto) con total original, total reconfigurado y diferencia; carga el último pedido del cliente dentro de la ventana, o el reconfigurado si ya lo había. Cuatro bloques de sugerencias con afinidad, cantidad, importe y motivo; “Cambiar” en upselling y “Agregar” en el resto; el ticket marca con color el origen de cada línea. Botones: **Enviar a PDF**, Descargar pedido, Volver al último pedido.

**Vista de grupo** (dos o más clientes): 
- Indicadores: clientes, pedidos originales, pedidos reconfigurados, diferencia aceptada, upselling pendiente y cross-selling pendiente.
- Las cuatro listas de sugerencias **sumadas por producto**: a cuántos clientes se les sugiere, unidades, importe y afinidad media, ordenadas por cantidad de clientes; se muestran 8 y el resto va al PDF y a la descarga. Botón **“Aplicar a los N”** que reconfigura de una vez el pedido de cada cliente al que se le sugiere ese producto.
- Tabla de clientes del grupo (original, reconfigurado, diferencia, sugerencias pendientes) con botón **Abrir** para entrar al pedido individual; desde ahí, **Volver al grupo** muestra lo cambiado.
- Pedido consolidado del grupo (SKU, clientes, cantidad, importe).
- Botones: **Enviar a PDF**, Descargar, Cambiar el grupo, Volver a un solo cliente.
- Los pedidos tocados se conservan en la sesión al cambiar de cliente o de grupo, aunque el cliente quede fuera del grupo nuevo, y se guardan todos con “Guardar cambios”.

### Resto de las secciones

- **Oportunidades**: plan de toda la cartera con indicadores, barras por segmento, productos más sugeridos, filtros por segmento, tipo y oportunidad (los tres con opción “Todos” / “Ambas”), tabla con el motivo, **Enviar a PDF** y descarga.
- **Pedidos atípicos**: pedido, fecha, cliente, segmento, rareza, productos y cantidades inusuales, importe; descarga; contador en el menú.
- **Datos**: indicadores; control de calidad; carga de CSV o Excel para cada tabla (agrega filas nuevas; no pisa las existentes); altas manuales de cliente y de producto; informe de filas nuevas y rechazadas; plantilla de carga; descarga de las tres tablas. **Reemplazar toda la base**: tres selectores de archivo (productos, clientes, pedidos) y un botón que, previa confirmación, valida las filas, descarta la base actual (la de ejemplo o una anterior), entrena de cero y descarta los pedidos reconfigurados; es la forma de pasar a los datos reales y de corregir datos ya cargados, como precios; si falta un archivo o no queda ninguna línea de pedido válida, no cambia nada y lo explica. **Respaldo** en un archivo JSON (la base propia si se reemplazó, lo cargado después, ventana, parámetros y pedidos reconfigurados) y su restauración para pasar el trabajo a otra computadora; volver a los datos de ejemplo. Después de cada carga el modelo se actualiza en caliente. La base propia se guarda con “Guardar cambios” y se recupera al reabrir.
- **Modelo**: indicadores; comparación RBM contra lo más vendido del segmento; curva de error; parámetros editables y acotados (unidades ocultas, modelos del conjunto, épocas, tasa, ventana móvil, meses de perfil, umbral de atípico); botones Actualizar rápido, Reentrenar completo, Afinar automáticamente y Descargar modelo; historial de entrenamientos con su ventana.

- **Manual de uso** (última pestaña del menú): guía completa para el usuario de Compras, escrita en lenguaje llano, con índice de capítulos que lleva a cada uno, botón “Volver al índice” y botón “Enviar el manual a PDF”. El contenido se define una sola vez como estructura de datos (capítulos con partes; cada parte con subtítulo, párrafos, pasos numerados y tabla) y de ahí salen la pestaña y el PDF. Para cada función explica qué es, para qué sirve, cómo se hace paso a paso, qué significa cada dato y qué se obtiene. Capítulos: 1) para qué sirve y cómo está organizado; 2) primeros pasos; 3) la ventana de análisis; 4) guardar cambios y respaldo; 5) segmentar y elegir con quién trabajar; 6) armar el pedido de un cliente (las cuatro listas, afinidad, motivo, cantidad típica, importe); 7) grupo o toda la cartera; 8) oportunidades; 9) pedidos atípicos; 10) datos: tablas, columnas, pasar a datos reales, agregar datos, motivos de rechazo y control de calidad; 11) modelo: qué es, cómo se mide, parámetros y botones; 12) informes y descargas; 13) rutina de trabajo sugerida (por pedido, semanal, mensual, al cambiar catálogo, semestral); 14) preguntas frecuentes y problemas; 15) glosario. El manual no puede afirmar nada que el tablero no haga: verificar cada frase contra el comportamiento real.

### Informes PDF (A4, paginados, con pie de emisión)

Un mismo generador recibe una estructura neutra (título, líneas de encabezado, bloques con párrafos y tablas) y la emite con jsPDF o, sin internet, con la impresión del navegador. Limpiar los caracteres que la fuente estándar no tiene.

- **Recomendación de un cliente**: cliente, tipo, segmento y provincia; ventana de análisis; fecha y precisión del modelo; resumen (original, reconfigurado, diferencia, sugerencias aceptadas y pendientes); pedido reconfigurado con el origen de cada línea; upselling, cross-selling, reposición y novedades con afinidad, cantidad, importe y motivo; nota de cómo leer el informe.
- **Recomendación de un grupo**: segmentos incluidos; resumen; las cuatro tablas por producto; clientes del grupo; detalle por cliente de todas las sugerencias pendientes; pedido consolidado.
- **Plan de la cartera**: resumen por segmento y detalle por cliente, respetando los filtros.
- **Manual de uso**: todos los capítulos, con sus pasos y tablas.

## 5. El motor en R (espejo, opcional)

Mismo algoritmo, mismos parámetros y mismas reglas que el HTML, en R base (sin paquetes; `readxl` sólo para leer Excel). `ejecutar.R` acepta `--desde=`, `--hasta=`, `--completo` y `--afinar`; incorpora lo que haya en `datos/entrada/` (archivos cuyo nombre contenga pedidos, clientes o productos, en ese orden: productos, clientes, pedidos; luego pasan a `datos/procesados/`), valida, entrena o actualiza, guarda el modelo y un historial, y deja en `salidas/` el plan de oportunidades y los pedidos atípicos. Decide solo: sin modelo entrena completo; con datos nuevos actualiza en caliente; si cambia la ventana o tras 10 actualizaciones seguidas reentrena completo; sin cambios no reentrena. Con errores de calidad en los datos, se detiene y los lista.

## 6. Pruebas de aceptación (ejecutarlas y mostrar el resultado)

No des nada por terminado sin correr estas pruebas en los dos motores y en un navegador real:

- Las tres tablas sin errores de integridad; matriz binaria, sin filas vacías, con un tipo y un segmento por fila.
- Pesos finitos, error de reconstrucción decreciente y entrenamiento reproducible con la misma semilla.
- La RBM supera a lo más vendido del segmento en acierto top 5 y en cobertura top 10.
- Para **todos** los clientes: sin sugerencias duplicadas entre listas, sin productos que ya compra, afinidad entre 0 y 1, upselling siempre de la misma subfamilia y más caro, cross-selling sólo en subfamilias no cubiertas, motivo presente.
- Cliente nuevo sin historia recibe sugerencias por tipo y segmento.
- Se detecta al menos el 60 % de los pedidos atípicos inyectados sin marcar más de 60 pedidos.
- Ventana desde/hasta: los pedidos respetan el rango; el modelo se reentrena y recomienda; fechas invertidas y ventana sin pedidos dan un mensaje claro.
- Carga: producto nuevo con encabezados de ERP y punto y coma, cliente nuevo de un segmento nuevo y pedidos; se rechazan con motivo el cliente inexistente, la fecha mal escrita, la cantidad cero y el cliente sin segmento; el modelo incorpora las unidades nuevas y recomienda al cliente nuevo.
- Segmentación: los dos filtros arrancan en “Todos”; Todos + Todos da la cartera; segmento con tipo Todos, tipo con segmento Todos y la combinación dan las cantidades correctas y filtran el buscador; el botón arma el grupo de esa segmentación; cliente nuevo con “Todos” pide valores concretos.
- Grupo: toda la cartera y un grupo elegido a mano; “Aplicar a los N” cambia los totales; abrir un cliente, cambiarlo y verlo reflejado al volver; guardar conserva también los pedidos de clientes que quedaron fuera del grupo; el grupo se recalcula al cambiar la ventana.
- Reemplazo de la base: sin los tres archivos avisa; con tres archivos válidos (encabezados de ERP incluidos) cambia la base, toma los precios nuevos, entrena de cero y actualiza los filtros; guardar y reabrir conserva la base propia; el respaldo la incluye y la restaura; con pedidos inválidos no reemplaza nada.
- Manual: 15 capítulos con índice que lleva a cada uno; PDF completo y sin caracteres rotos; legible en celular sin desborde.
- En navegador, con y sin internet: aceptar sugerencias, guardar, recargar y recuperar el pedido; generar los PDF y verificar su texto; descargas; respaldo, reinicio y restauración; modo celular sin desborde horizontal; consola sin errores.

## 7. Cierre

Entregá los archivos y un resumen breve con: qué se construyó, las cifras reales de la evaluación en cada motor, cuántos atípicos se detectaron, qué pruebas se corrieron y la advertencia de que los datos de ejemplo tienen estructura diseñada, por lo que con datos reales hay que mirar la comparación contra lo más vendido del segmento antes de confiar en las sugerencias. Aclarar también que “Guardar cambios” guarda en el navegador de esa computadora y que para compartir el trabajo se usa el respaldo.
