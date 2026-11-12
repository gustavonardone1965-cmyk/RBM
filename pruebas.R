# =====================================================================
#  pruebas.R — Batería de pruebas automáticas del cerebro R.
#  Uso: Rscript R/pruebas.R   (trabaja sobre una copia temporal de datos/)
# =====================================================================
args_todos <- commandArgs(trailingOnly = FALSE)
archivo <- sub("^--file=", "", args_todos[grepl("^--file=", args_todos)])
ORIGEN <- if (length(archivo)) normalizePath(file.path(dirname(archivo), "..")) else getwd()
BASE_DIR <- file.path(tempdir(), "rbm_pruebas"); unlink(BASE_DIR, recursive = TRUE)
dir.create(file.path(BASE_DIR, "datos", "entrada"), recursive = TRUE)
invisible(file.copy(file.path(ORIGEN, "datos", c("clientes.xlsx", "productos.xlsx", "pedidos.xlsx")), file.path(BASE_DIR, "datos")))
source(file.path(ORIGEN, "R", "rbm_core.R"), encoding = "UTF-8"); source(file.path(ORIGEN, "R", "pipeline.R"), encoding = "UTF-8")
ok <- function(cond, texto) { if (!isTRUE(cond)) stop("FALLA: ", texto, call. = FALSE); cat("  ok  ", texto, "\n") }

cat("1. Fechas\n")
ok(sumar_meses("2026-10-31", -6) == as.Date("2026-04-30"), "fin de mes: 31/10 - 6 meses = 30/04")
ok(sumar_meses("2026-01-15", -3) == as.Date("2025-10-15"), "cruce de año")
ok(sumar_meses("2024-03-31", -1) == as.Date("2024-02-29"), "año bisiesto")

cat("2. Datos (los tres Excel)\n")
d <- leer_datos()
ok(nrow(d$productos) == 82 && nrow(d$clientes) == 89 && nrow(d$todos) == 22699, sprintf("se leen los tres Excel: %d productos, %d clientes, %d líneas de pedido", nrow(d$productos), nrow(d$clientes), nrow(d$todos)))
ok(all(grepl("^\\d{4}-\\d{2}-\\d{2}$", format(d$todos$fecha))) && is.numeric(d$todos$cantidad) && is.character(d$todos$sku), "fechas, números y códigos con el tipo correcto")
ok(identical(normalizar_fecha(c("30/10/2026", "2026-10-30 00:00:00", "46325", "ayer")), c("2026-10-30", "2026-10-30", "2026-10-30", "ayer")), "fechas de planilla: dd/mm/aaaa, con hora y número de serie de Excel")
ok(nrow(validar_datos(d)[validar_datos(d)$nivel == "error", ]) == 0, "las tres tablas no tienen errores de integridad")
X <- construir_matriz(d)
ok(all(X %in% c(0, 1)) && all(rowSums(X[, d$productos$sku]) > 0), "matriz binaria, sin filas vacías")
ok(all(rowSums(X[, grepl("^TIPO:", colnames(X))]) == 1) && all(rowSums(X[, grepl("^SEG:", colnames(X))]) == 1), "cada fila tiene un tipo y un segmento")

cat("3. Entrenamiento\n")
mod <- entrenar(d, PARAMS_DEFECTO, "completo")
ok(length(mod$rbms) == 3 && all(sapply(mod$rbms, function(m) all(is.finite(m$W)) && all(is.finite(m$b)) && all(is.finite(m$c)))), "3 RBM con pesos finitos")
ok(all(sapply(mod$rbms, function(m) tail(m$curva, 1) < m$curva[1])), "el error de reconstrucción baja")
ok(mod$metricas$hit5_rbm > mod$metricas$hit5_base && mod$metricas$recall10_rbm > mod$metricas$recall10_base, sprintf("supera a lo más vendido del segmento (top5 %.3f vs %.3f, top10 %.3f vs %.3f)", mod$metricas$hit5_rbm, mod$metricas$hit5_base, mod$metricas$recall10_rbm, mod$metricas$recall10_base))
mod_b <- entrenar(d, PARAMS_DEFECTO, "completo", evaluar_modelo = FALSE)
ok(identical(mod_b$rbms[[1]]$W, mod$rbms[[1]]$W), "entrenamiento reproducible (misma semilla, mismos pesos)")

cat("4. Umbral de recomendación\n")
ok(mod$params$umbral_reco == 0.7, "umbral por defecto: 70%")
conteo <- function(u) { m <- mod; m$params$umbral_reco <- u
  sum(sapply(d$clientes$id_cliente, function(id) { r <- recomendar(m, d, id); nrow(r$upselling) + nrow(r$cross_selling) })) }
n70 <- conteo(0.7); n50 <- conteo(0.5)
ok(n50 > n70, sprintf("con 70%% quedan %d sugerencias y con 50%% %d", n70, n50))
for (u in c(0.5, 0.7, 0.9)) { m <- mod; m$params$umbral_reco <- u
  for (id in d$clientes$id_cliente) { r <- recomendar(m, d, id)
    if (any(c(r$upselling$score, r$cross_selling$score) < u)) stop("FALLA: sugerencia por debajo del umbral ", u, " en ", id, call. = FALSE) } }
cat("  ok   ningún upselling ni cross-selling por debajo del umbral (probado con 50%, 70% y 90%)\n")
r0 <- recomendar(mod, d, "CLI-0040")
ok(nrow(r0$reposicion) > 0 && nrow(r0$novedades) > 0, "reposición y novedades siguen su propia regla, no el umbral")

cat("5. Recomendaciones (toda la cartera)\n")
pr <- d$productos
for (id in d$clientes$id_cliente) {
  r <- recomendar(mod, d, id); pf <- perfil_cliente(d, id, 12); tiene <- names(pf)[pf > 0]
  todos <- c(r$upselling$sku, r$cross_selling$sku, r$novedades$sku)
  if (anyDuplicated(todos)) stop("FALLA: sugerencia duplicada en ", id)
  if (any(todos %in% tiene)) stop("FALLA: se sugiere algo que ya compra ", id)
  sc <- c(r$upselling$score, r$cross_selling$score, r$novedades$score)
  if (any(!is.finite(sc) | sc < 0 | sc > 1)) stop("FALLA: puntaje fuera de [0,1] en ", id)
  if (nrow(r$upselling)) { b <- pr[match(r$upselling$reemplaza, pr$sku), ]
    if (any(b$subfamilia != r$upselling$subfamilia | r$upselling$precio_lista <= b$precio_lista | r$upselling$incremental <= 0)) stop("FALLA: upselling inválido en ", id) }
  if (any(r$cross_selling$subfamilia %in% pr$subfamilia[pr$sku %in% tiene])) stop("FALLA: cross-selling en subfamilia ya cubierta en ", id)
}
cat("  ok   89 clientes: sin duplicados, sin productos ya comprados, upselling siempre superior, cross-selling en subfamilias nuevas\n")
rn <- recomendar(mod, d, NULL, canasta = c("QUI-001", "NO-EXISTE"), tipo = "Externo", segmento = "Salud")
ok(nrow(rn$cross_selling) > 0 && nrow(rn$reposicion) == 0, "cliente nuevo: recomienda por tipo y segmento, ignora SKU inexistentes")
ok(any(nzchar(recomendar(mod, d, "CLI-0040")$cross_selling$motivo)), "las sugerencias traen motivo")

cat("6. Pedidos atípicos y plan\n")
a <- detectar_anomalias(mod, d)
ctrl <- leer_excel(file.path(ORIGEN, "salidas", "control_pedidos_atipicos_inyectados.xlsx"))$id_pedido
ok(mean(ctrl %in% a$id_pedido) >= 0.6 && nrow(a) < 60, sprintf("detecta %d de %d pedidos atípicos inyectados (%d marcados en total)", sum(ctrl %in% a$id_pedido), length(ctrl), nrow(a)))
pl <- plan_oportunidades(mod, d)
ok(nrow(pl) > 20 && all(pl$importe_incremental > 0) && all(pl$score >= mod$params$umbral_reco), sprintf("plan de oportunidades: %d sugerencias, todas sobre el umbral y con importe positivo", nrow(pl)))

cat("7. Ventana de análisis desde / hasta\n")
dv <- leer_datos(list(desde = "2025-07-01", hasta = "2026-06-30"))
ok(min(dv$pedidos$fecha) >= as.Date("2025-07-01") && max(dv$pedidos$fecha) <= as.Date("2026-06-30"), "los pedidos respetan la ventana")
mv <- entrenar(dv, PARAMS_DEFECTO, "completo")
ok(mv$filas < mod$filas && nrow(recomendar(mv, dv, "CLI-0040")$cross_selling) > 0, sprintf("entrena y recomienda dentro de la ventana (%d filas)", mv$filas))
ok(inherits(try(entrenar(leer_datos(list(desde = "2030-01-01")), PARAMS_DEFECTO), silent = TRUE), "try-error"), "ventana sin pedidos: error claro")

cat("8. Retroalimentación (Excel en datos/entrada)\n")
if (!requireNamespace("writexl", quietly = TRUE)) stop("Para las pruebas hace falta writexl: install.packages(\"writexl\")", call. = FALSE)
writexl::write_xlsx(data.frame(`SKU` = c("QUI-099", "QUI-001"), `Nombre` = c("Desinfectante ecológico 5 L", "Repetido"), `Familia` = c("Químicos de limpieza", "x"),
  `Sub Familia` = c("Desinfectantes", "y"), `Precio Lista` = c(22000, 1), check.names = FALSE), file.path(BASE_DIR, "datos", "entrada", "productos_nov.xlsx"))
writexl::write_xlsx(data.frame(`ID Cliente` = c("CLI-0500", "CLI-0501"), `Razón Social` = c("Laboratorio Nuevo", "Sin segmento"), Tipo = "Externo",
  Segmento = c("Farmacéutica", NA), check.names = FALSE), file.path(BASE_DIR, "datos", "entrada", "clientes_nov.xlsx"))
writexl::write_xlsx(data.frame(id_pedido = c("PED-900001", "PED-900001", "PED-900002", "PED-900003", "PED-900004"),
  fecha = c(as.Date("2026-10-30"), as.Date("2026-10-30"), as.Date("2026-10-30"), NA, as.Date("2026-10-30")),
  id_cliente = c("CLI-0500", "CLI-0500", "CLI-9999", "CLI-0500", "CLI-0500"), sku = c("QUI-099", "HIG-003", "QUI-099", "QUI-099", "QUI-099"),
  cantidad = c(4, 2, 4, 4, 0)), file.path(BASE_DIR, "datos", "entrada", "pedidos_nov.xlsx"))
log <- suppressMessages(procesar_entrada())
ok(identical(log$filas_nuevas, c(1L, 1L, 2L)) && identical(log$rechazadas, c(0L, 1L, 3L)), "ingesta desde Excel: 1 producto, 1 cliente y 2 líneas nuevas; rechaza cliente sin segmento, cliente inexistente, fecha vacía y cantidad cero")
ok(length(list.files(file.path(BASE_DIR, "datos", "entrada"))) == 0 && length(list.files(file.path(BASE_DIR, "datos", "procesados"))) == 3, "los archivos pasan a datos/procesados")
d2 <- leer_datos()
ok(nrow(validar_datos(d2)[validar_datos(d2)$nivel == "error", ]) == 0, "la base sigue íntegra después de la carga")
guardar_modelo(mod); m2 <- asegurar_modelo(d2)
ok(m2$modo == "actualizar" && all(c("QUI-099", "SEG:Farmacéutica") %in% nombres_modelo(m2)) && all(is.finite(m2$rbms[[1]]$W)), "actualización en caliente: incorpora el producto y el segmento nuevos")
m3 <- m2; m3$params$umbral_reco <- 0.5
ok(nrow(recomendar(m3, d2, "CLI-0500")$cross_selling) > 0 && recomendar(m2, d2, "CLI-0500")$descartadas > 0,
   "recomienda al cliente nuevo de un segmento nuevo cuando el umbral lo permite (con 70% sus propuestas quedan por debajo y se informan como descartadas)")
ok(identical(asegurar_modelo(d2)$fecha, m2$fecha), "sin cambios en los datos no reentrena")
ok(suppressMessages(procesar_entrada()) |> nrow() == 0, "carpeta de entrada vacía: no hace nada")
ok(file.exists(file.path(BASE_DIR, "datos", "productos.xlsx")) && nrow(leer_tabla("productos")) == 83, "las bases se reescriben en Excel")

cat("\nTODAS LAS PRUEBAS R OK\n")
