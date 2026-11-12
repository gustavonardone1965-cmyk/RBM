# Prompt maestro — Recomendador RBM de Compras

Versión consolidada del 11 de noviembre de 2026. Reemplaza a todas las anteriores. Incluye: el motor RBM en conjunto dentro del HTML, las bases en tres archivos de Excel, el umbral de recomendación, la ventana de análisis, el guardado y el respaldo, el trabajo por cliente, grupo o cartera con segmentación “Todos”, los informes en PDF, el manual de uso embebido y el motor R complementario.

Copiar todo lo que sigue en un asistente que pueda ejecutar código y generar archivos. Los valores entre corchetes se pueden cambiar antes de pegarlo.

---

## Rol y objetivo

Sos un especialista en machine learning aplicado a supply chain, con dominio de JavaScript, R y diseño de interfaces. Tenés que construir de punta a punta un **recomendador de productos para el área de Compras** de [EcoClean, empresa de servicios y artículos de limpieza con sede en Córdoba, Argentina], basado en una **Máquina de Boltzmann Restringida (RBM)**.

Objetivo de negocio: cuando entra un pedido de un cliente interno (un contrato o sitio propio que pide insumos a Compras central) o externo (un cliente que compra artículos), Compras debe poder **reconfigurarlo** para lograr upselling y cross-selling, en clientes existentes y nuevos, de a un cliente, por grupo o para toda la cartera, y detectar pedidos atípicos antes de comprar.

Dos restricciones que mandan sobre todo lo demás:

1. **El producto es un único archivo HTML autónomo.** Quien lo usa todos los días es personal de Compras que no sabe programar ni va a aprender R. El HTML entrena la RBM, recomienda, guarda, lee y escribe Excel y emite los informes, todo en el navegador, sin servidor, sin instalar nada y sin conexión a internet. R es **complementario**: no corre en segundo plano, no hace falta para operar y nada del circuito diario depende de él.
2. **Las bases son tres archivos de Excel**, uno por tabla, con una sola hoja cada uno: `productos.xlsx`, `clientes.xlsx`, `pedidos.xlsx`. Nada de CSV como formato de trabajo: la empresa mantiene esos tres archivos, los edita en Excel y los vuelve a cargar. El tablero los lee y los escribe por su cuenta.

Idioma de todo lo visible: español rioplatense, claro y sin jerga técnica en la interfaz. Moneda: pesos argentinos con formato `$ 1.234.567`. No inventes resultados: todo número que informes tiene que salir de una corrida real.

## Entregables

1. `www/index.html`: tablero autónomo con el motor RBM en JavaScript, el lector y escritor de Excel, los datos de ejemplo, un modelo preentrenado y el manual de uso, todo embebido (abre al instante, sin entrenar).
2. `datos/productos.xlsx`, `datos/clientes.xlsx`, `datos/pedidos.xlsx`: las tres bases de ejemplo, con encabezados en negrita, fila fija, autofiltro, anchos de columna, fechas con formato y listas desplegables en los campos con valores fijos (gama, tipo_item, activo, tipo, tamano). Más `datos/Base_inicial_RBM.xlsx` con el diccionario de datos, las tres tablas y una hoja con la matriz cliente × producto calculada con fórmulas.
3. `R/rbm_core.R` (la RBM), `R/pipeline.R` (lógica de negocio), `R/ejecutar.R` (corrida por línea de comandos), `R/pruebas.R` (pruebas automáticas) y un `.bat` para Windows que aclare que R es opcional.
4. `LEEME.md` con uso, estructura y funcionamiento.

## 1. Las tres bases de Excel

Una hoja por archivo, encabezados en la primera fila con contenido. Nombres de columna exactos:

**productos**: `sku` (clave), `nombre`, `familia`, `subfamilia`, `unidad`, `gama` (Estándar / Premium), `tipo_item` (C = consumible, E = equipo), `precio_lista`, `sku_superior` (SKU de la versión superior; puede ir vacío), `fecha_alta`, `activo` (Sí / No).

**clientes**: `id_cliente` (clave), `razon_social`, `tipo` (Interno / Externo), `segmento`, `provincia`, `pais`, `tamano` (Chico / Mediano / Grande), `fecha_alta`.

**pedidos** (una fila por línea): `id_pedido`, `fecha`, `id_cliente`, `sku`, `cantidad`, `precio_unitario`, `canal`. Clave: `id_pedido` + `sku`.

La `subfamilia` agrupa productos sustitutos y separa upselling (misma subfamilia) de cross-selling (otra subfamilia). `tipo` y `segmento` son además unidades de contexto del modelo.

**Lectura tolerante, porque los archivos los edita gente**: encabezados con mayúsculas, acentos y espacios; sinónimos de ERP (código / artículo → `sku`; descripción / producto → `nombre`; sub familia → `subfamilia`; precio → `precio_lista`; pedido / nro pedido / orden → `id_pedido`; cliente / cod cliente → `id_cliente`; cant → `cantidad`; rubro → `segmento`), sin que un sinónimo pise una columna que ya vino con su nombre correcto; fechas como fecha de Excel, como número de serie, o como texto en AAAA-MM-DD o DD/MM/AAAA; códigos numéricos tratados como texto (un SKU 00123 no pierde los ceros); filas y columnas vacías ignoradas. Se acepta también CSV (coma o punto y coma, comillas, BOM) como alternativa, pero no es el formato de trabajo.

**Control de calidad** (calcularlo y mostrarlo siempre). Errores: claves repetidas; líneas con cliente o SKU inexistente; fecha inválida; cantidad cero o negativa; `sku_superior` inexistente; cliente sin tipo o sin segmento; ventana sin pedidos. Avisos: productos sin precio; clientes sin pedidos en la ventana; productos sin ventas en la ventana; ventana de menos de 6 meses. Cada fila rechazada se informa con su número y el motivo.

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
- **Ventana de análisis**: un rango Desde / Hasta inclusivo, opcional. Todo (filas de entrenamiento, perfil, último pedido, evaluación, atípicos) usa sólo los pedidos de ese rango.
- **Filas de entrenamiento**: una por cliente y por ventana móvil de 6 meses, con paso de 3 meses y hasta 9 cortes hacia atrás desde la última fecha, sin pasar del inicio de la ventana de análisis; 1 si el cliente compró el SKU en esa ventana móvil. Las restas de meses respetan el fin de mes (31/10 menos 6 meses = 30/04).
- **Entrenamiento**: Contrastive Divergence CD-1; estado oculto muestreado en la fase positiva y probabilidades en la reconstrucción; minilotes de 16; tasa 0,05; momentum 0,5 las primeras 5 épocas y 0,9 después; weight decay 2e-4; 300 épocas; pesos iniciales N(0; 0,01); sesgo visible inicial igual al logit de la frecuencia de la columna (acotada entre 0,01 y 0,99); semilla fija y generador propio para que sea reproducible.
- **Conjunto**: 3 RBM de 8 unidades ocultas con semillas distintas; el puntaje es el promedio de sus probabilidades.
- **Eficiencia**: el entrenamiento completo de esta base debe tardar unos 15 segundos en el navegador y la recomendación de un cliente, menos de medio segundo. Usar arreglos tipados (Float64Array) y evitar copias por minilote. El HTML se publica con un modelo ya entrenado adentro, así que abre listo para usar.
- **Puntaje**: vector con los SKU del perfil del cliente (lo comprado en los últimos 12 meses de la ventana), más los del pedido en curso, más su tipo y segmento; se calcula p(h|v) y luego p(v|h) por campo medio. Esa probabilidad es la “afinidad”.
- **Evaluación**: ocultar al azar el 20 % de los productos de cada cliente con 5 o más (mínimo 1), entrenar sin ellos y medir acierto top 5 y cobertura top 10. Línea de base: lo más vendido del segmento. Mostrar siempre las dos cifras juntas.
- **Afinado automático**: probar 4, 8, 16 y 24 unidades ocultas y quedarse con la mejor.
- **Actualización en caliente**: ante datos nuevos, agregar unidades visibles para productos, tipos o segmentos nuevos (pesos N(0; 0,01), sesgo por frecuencia) y seguir entrenando 120 épocas con la mitad de la tasa. Si cambia la arquitectura o la ventana de análisis, reentrenar completo.

## 3. Reglas de recomendación

### Umbral de recomendación

Parámetro central: **sólo se proponen productos cuya afinidad llegue al umbral; el resto el motor los ignora**. Valor inicial **0,7**; ajustable en el HTML entre **0,5 y 1, de a 0,05**, con una barra deslizante en la sección Modelo que muestra el valor en porcentaje. **No es un parámetro de entrenamiento**: cambiarlo recalcula las sugerencias al instante, sin reentrenar, y se guarda con el resto del estado.

Alcanza a upselling y cross-selling, que son las propuestas que salen del modelo. **Reposición** (frecuencia de compra del cliente) y **novedades** (productos sin historia todavía) siguen su propia regla y no se filtran; decirlo en la interfaz. `recomendar` devuelve también el umbral usado y cuántas propuestas quedaron por debajo, para que la interfaz avise cuando una lista queda vacía por el umbral y no por falta de oportunidades.

### Las cuatro listas

Para un cliente y un pedido en curso, hasta 6 ítems por lista (novedades hasta 3), sin repetir productos entre listas y sin sugerir nada que el cliente ya compre o que ya esté en el pedido:

1. **Reposición**: productos presentes en 30 % o más de sus pedidos del período que faltan en el pedido actual, por frecuencia.
2. **Upselling**: para cada producto que usa, su `sku_superior` o un Premium de la misma subfamilia, activo y más caro, con afinidad ≥ umbral. Informar a cuál reemplaza y el importe incremental (diferencia de precio por cantidad típica).
3. **Cross-selling**: productos activos de subfamilias que el cliente todavía no cubre, con afinidad ≥ umbral, uno por subfamilia. Importe = precio de lista por cantidad típica.
4. **Novedades**: productos con alta en los últimos 120 días que no estén ya en upselling, por afinidad; si la afinidad es menor a 5 %, rotular “todavía sin historial: ofrecer como lanzamiento”.

**Cantidad típica**: mediana de la cantidad pedida de ese SKU en el segmento (mínimo 1). **Motivo**: los dos productos del cliente cuya ausencia más baja la probabilidad del candidato (se recalcula el puntaje quitándolos de a uno; caída mínima 0,01), mostrado como “Porque compra: …”.

**Aceptar una sugerencia**: en upselling la línea nueva reemplaza a la del producto base conservando su cantidad; en cross-selling se agrega con la cantidad típica; en reposición y novedades, con cantidad 1. La regla es la misma para un cliente y para un grupo.

**Pedidos atípicos**: para cada pedido del período del perfil, puntuar con el perfil del cliente sin ese pedido; marcar productos con probabilidad menor al umbral de atípico (5 % por defecto, ajustable, distinto del umbral de recomendación) que no estén en sus otros pedidos y no sean novedades; marcar cantidades con z mayor a 3 sobre el logaritmo de la historia cliente–SKU. Ordenar por rareza.

**Plan de oportunidades**: las mejores 3 de upselling y 3 de cross-selling para cada cliente de la cartera, respetando el umbral, con importe incremental y motivo.

## 4. El tablero HTML (producto principal)

Un solo archivo, sin servidor. Única librería externa: jsPDF 2.5.1 por `<script>` desde cdnjs con versión fija; si no carga (sin internet), el PDF sale por la impresión del navegador. **Excel se lee y se escribe con código propio**: un `.xlsx` es un ZIP de XML, y el navegador ya trae `CompressionStream` y `DecompressionStream`; no usar SheetJS ni ninguna librería externa para esto. El lector debe resolver cadenas compartidas, texto en línea, fechas por formato de celda, el sistema 1904 y la hoja referenciada por relación; el escritor debe producir archivos que abran en Excel y en LibreOffice, con encabezado en negrita, fila fija, autofiltro, anchos y fechas con formato.

Diseño sobrio para un escritorio de Compras, con modo claro y oscuro, usable en celular sin desborde horizontal, foco visible por teclado, y mensajes de error dentro de la página. Colores con significado fijo: amarillo = upselling, verde = cross-selling, gris azulado = reposición, violeta = novedades, rojo = atípico. El entrenamiento muestra un velo con texto de avance y, si falla, no reemplaza el modelo vigente.

### Franja superior, visible en todas las secciones

- **Ventana de análisis**: fechas Desde y Hasta (por defecto, todo el historial), “Aplicar ventana” y “Todo el historial”. Al aplicar se reentrena completo. Validar fechas invertidas y rango sin pedidos. Al cambiar la ventana se descartan los pedidos reconfigurados sin guardar.
- **Guardar cambios**: persiste en el navegador (IndexedDB) la base propia, lo cargado después, la ventana, los parámetros (umbral incluido), el modelo, el historial y todos los pedidos reconfigurados. Indicador: “Sin cambios”, “Cambios sin guardar” o “Guardado el …”. Avisar antes de cerrar con cambios sin guardar. Al reabrir se restaura todo; si el navegador no permite guardar, decirlo y remitir al respaldo.

### Sección Armar pedido

**Segmentación**: desplegable **Tipo de cliente** con **Todos**, Interno, Externo, y desplegable **Segmento** con **Todos** y cada segmento; ambos arrancan en “Todos” y se combinan. Botón **Armar grupo** con texto dinámico (“Armar grupo con estos N clientes”; deshabilitado si no hay ninguno; con uno solo, abre ese cliente). Botón **Elegir clientes a mano** (diálogo con búsqueda, los mismos filtros con “Todos”, casillas, “Marcar los que se ven”, “Quitar los que se ven”, contador). Botón **Todos los clientes**. Buscador de cliente filtrado por la segmentación, con rótulo “Cliente (N de M con este tipo y segmento)”. “Empezar con cliente nuevo” exige tipo y segmento concretos.

**Vista de un cliente**: ticket editable (cantidades, quitar, agregar producto) con total original, reconfigurado y diferencia; carga el último pedido del cliente en la ventana o el reconfigurado guardado. Cuatro bloques de sugerencias con afinidad, cantidad, importe y motivo; “Cambiar” en upselling y “Agregar” en el resto; color por origen en cada línea; cuando una lista queda vacía por el umbral, decirlo. Botones: **Enviar a PDF**, Descargar pedido (Excel), Volver al último pedido.

**Vista de grupo**: indicadores (clientes, pedidos originales, reconfigurados, diferencia aceptada, upselling y cross-selling pendientes); las cuatro listas **sumadas por producto** (clientes, unidades, importe, afinidad media), con botón **“Aplicar a los N”** que reconfigura de una vez el pedido de cada cliente al que se le sugiere; tabla de clientes con botón **Abrir** y **Volver al grupo**; pedido consolidado; **Enviar a PDF**, Descargar (Excel), Cambiar el grupo, Volver a un solo cliente. Los pedidos tocados se conservan al cambiar de cliente o de grupo y se guardan todos.

### Resto de las secciones

- **Oportunidades**: plan de la cartera con indicadores, barras por segmento, productos más sugeridos, filtros (segmento, tipo, oportunidad, los tres con “Todos”), tabla con el motivo, **Enviar a PDF** y descarga en Excel.
- **Pedidos atípicos**: pedido, fecha, cliente, segmento, rareza, productos y cantidades inusuales, importe; descarga en Excel; contador en el menú.
- **Datos**: indicadores; control de calidad; **Reemplazar toda la base** con los tres Excel (tres selectores y un botón que, previa confirmación, valida, descarta la base anterior, entrena de cero y descarta los pedidos reconfigurados; si falta un archivo o no queda ninguna línea válida, no cambia nada y lo explica); carga por tabla para agregar filas; altas manuales de cliente y producto; informe de filas nuevas y rechazadas; **plantilla en Excel** con una hoja por tabla; descarga de los tres Excel completos tal como están en el tablero; **respaldo** en JSON y su restauración; volver a los datos de ejemplo. Después de cada carga el modelo se actualiza en caliente.
- **Modelo**: indicadores; comparación contra lo más vendido del segmento; curva de error; **barra del umbral de recomendación** (0,5 a 1, paso 0,05) con su explicación; parámetros editables y acotados (unidades ocultas, modelos del conjunto, épocas, tasa, ventana móvil, meses de perfil, umbral de atípico); botones Actualizar rápido, Reentrenar completo, Afinar automáticamente, Descargar modelo; historial de entrenamientos con su ventana.
- **Manual de uso** (última pestaña): guía completa en lenguaje llano, con índice que lleva a cada capítulo, “Volver al índice” y “Enviar el manual a PDF”. El contenido se define una sola vez como estructura de datos (capítulos con partes; cada parte con subtítulo, párrafos, pasos numerados y tabla) y de ahí salen la pestaña y el PDF. Capítulos: 1) para qué sirve y cómo está organizado; 2) primeros pasos; 3) ventana de análisis; 4) guardar y respaldo; 5) segmentar y elegir con quién trabajar; 6) pedido de un cliente; 7) grupo o cartera; 8) el umbral de recomendación; 9) oportunidades; 10) pedidos atípicos; 11) datos: los tres Excel; 12) modelo; 13) informes y descargas; 14) rutina de trabajo sugerida; 15) preguntas frecuentes; 16) glosario. El manual no puede afirmar nada que el tablero no haga: verificar cada frase contra el comportamiento real.

### Informes PDF (A4, paginados, con pie de emisión)

Un generador único recibe una estructura neutra (título, líneas de encabezado, bloques con párrafos y tablas) y la emite con jsPDF o, sin internet, con la impresión del navegador. El encabezado de cada informe indica la ventana de análisis, la fecha y precisión del modelo y **el umbral de recomendación usado**.

- **Recomendación de un cliente**: datos del cliente; resumen (original, reconfigurado, diferencia, aceptadas y pendientes); pedido reconfigurado con el origen de cada línea; las cuatro listas con afinidad, cantidad, importe y motivo; nota de cómo leerlo.
- **Recomendación de un grupo**: segmentos; resumen; las cuatro tablas por producto; clientes del grupo; detalle por cliente; pedido consolidado.
- **Plan de la cartera**: resumen por segmento y detalle por cliente, según los filtros.
- **Manual de uso**: todos los capítulos con sus pasos y tablas.

## 5. El motor en R (complementario)

Mismo algoritmo, mismos parámetros y mismas reglas que el HTML, en R base. Lee **los mismos tres Excel** con `readxl` (y escribe con `writexl`), aplicando la misma normalización de encabezados, fechas y tipos; si en lugar de un `.xlsx` hay un `.csv` con el mismo nombre, también lo lee. `ejecutar.R` acepta `--desde=`, `--hasta=`, `--umbral=`, `--completo` y `--afinar`; incorpora lo que haya en `datos/entrada/` (archivos cuyo nombre contenga pedidos, clientes o productos, en ese orden; luego pasan a `datos/procesados/`), valida, entrena o actualiza, guarda el modelo y un historial, y deja en `salidas/` el plan de oportunidades y los pedidos atípicos **en Excel**. Decide solo: sin modelo entrena completo; con datos nuevos actualiza en caliente; si cambia la ventana o tras 10 actualizaciones seguidas reentrena completo; sin cambios no reentrena. Con errores de calidad se detiene y los lista. El `.bat` tiene que aclarar que el tablero funciona sin R.

## 6. Pruebas de aceptación (ejecutarlas y mostrar el resultado)

No des nada por terminado sin correr estas pruebas en los dos motores y en un navegador real, con y sin internet:

- Las tres bases sin errores de integridad; matriz binaria, sin filas vacías, con un tipo y un segmento por fila.
- Pesos finitos, error de reconstrucción decreciente y entrenamiento reproducible con la misma semilla.
- La RBM supera a lo más vendido del segmento en acierto top 5 y en cobertura top 10.
- Para **todos** los clientes: sin sugerencias duplicadas entre listas, sin productos que ya compra, afinidad entre 0 y 1, upselling siempre de la misma subfamilia y más caro, cross-selling sólo en subfamilias no cubiertas, motivo presente.
- Umbral: con 0,5, 0,7 y 0,9 ninguna sugerencia queda por debajo; bajarlo aumenta la cobertura; reposición y novedades no se filtran; el umbral sobrevive a un entrenamiento, se guarda y aparece en los PDF; moverlo recalcula en menos de 4 segundos sin reentrenar.
- Excel: las tres bases se leen completas y coinciden con los datos de origen; escribir y volver a leer conserva acentos, símbolos, saltos de línea, ceros a la izquierda, números y fechas; lo escrito abre en Excel (openpyxl) y en LibreOffice, y lo que guarda LibreOffice se vuelve a leer igual; un Excel de otro origen con encabezados de ERP, fechas dd/mm/aaaa y códigos numéricos se carga bien; un archivo que no es Excel da un mensaje claro.
- Ciclo completo: descargar los tres Excel del tablero, editarlos en Excel (cambiar un precio, agregar un producto) y volver a cargarlos con “Reemplazar toda la base”; la base queda como corresponde, sin errores de calidad; volver a cargar un Excel ya incorporado no duplica nada.
- Ventana desde/hasta: los pedidos respetan el rango; el modelo se reentrena y recomienda; fechas invertidas y ventana sin pedidos dan un mensaje claro.
- Carga: producto nuevo, cliente nuevo de un segmento nuevo y pedidos; se rechazan con motivo el cliente inexistente, la fecha ilegible, la cantidad cero y el cliente sin segmento; el modelo incorpora las unidades nuevas.
- Segmentación: los dos filtros arrancan en “Todos”; cada combinación da las cantidades correctas y filtra el buscador; el botón arma el grupo; cliente nuevo con “Todos” pide valores concretos.
- Grupo: toda la cartera y un grupo elegido a mano; “Aplicar a los N” cambia los totales; abrir un cliente, cambiarlo y verlo reflejado al volver; guardar conserva también los pedidos de clientes fuera del grupo; el grupo respeta el umbral y la ventana.
- Manual: 16 capítulos con índice que lleva a cada uno; PDF completo y sin caracteres rotos; legible en celular sin desborde.
- Rendimiento: el tablero abre y queda listo en menos de 12 segundos con el modelo embebido; consola sin errores; móvil sin desborde horizontal.
- Respaldo, reinicio y restauración; guardar, recargar y recuperar el pedido reconfigurado; generar todos los PDF y verificar su texto.

## 7. Cierre

Entregá los archivos y un resumen breve con: qué se construyó, las cifras reales de la evaluación en cada motor, cuántos atípicos se detectaron, qué pruebas se corrieron y **cuántas sugerencias deja el umbral elegido** (con 0,7 quedan pocas y muchos clientes sin propuestas: decirlo con números y explicar cómo bajarlo). Advertir que los datos de ejemplo tienen estructura diseñada, por lo que con datos reales hay que mirar la comparación contra lo más vendido del segmento antes de confiar en las sugerencias, y que “Guardar cambios” guarda en el navegador de esa computadora, por lo que para compartir el trabajo se usa el respaldo o los tres Excel.
