# =====================================================================
#  pruebas.R — Batería de pruebas automáticas del cerebro R.
#  Uso: Rscript R/pruebas.R   (trabaja sobre una copia temporal de datos/)
# =====================================================================
args_todos <- commandArgs(trailingOnly = FALSE)
archivo <- sub("^--file=", "", args_todos[grepl("^--file=", args_todos)])
ORIGEN <- if (length(archivo)) normalizePath(file.path(dirname(archivo), "..")) else getwd()
BASE_DIR <- file.path(tempdir(), "rbm_pruebas"); unlink(BASE_DIR, recursive = TRUE)
dir.create(file.path(BASE_DIR, "datos", "entrada"), recursive = TRUE)
invisible(file.copy(file.path(ORIGEN, "datos", c("clientes.csv", "productos.csv", "pedidos.csv")), file.path(BASE_DIR, "datos")))
source(file.path(ORIGEN, "R", "rbm_core.R"), encoding = "UTF-8"); source(file.path(ORIGEN, "R", "pipeline.R"), encoding = "UTF-8")
ok <- function(cond, texto) { if (!isTRUE(cond)) stop("FALLA: ", texto, call. = FALSE); cat("  ok  ", texto, "\n") }

cat("1. Fechas\n")
ok(sumar_meses("2026-10-31", -6) == as.Date("2026-04-30"), "fin de mes: 31/10 - 6 meses = 30/04")
ok(sumar_meses("2026-01-15", -3) == as.Date("2025-10-15"), "cruce de año")
ok(sumar_meses("2024-03-31", -1) == as.Date("2024-02-29"), "año bisiesto")

cat("2. Datos\n")
d <- leer_datos()
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

cat("4. Recomendaciones (toda la cartera)\n")
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

cat("5. Pedidos atípicos y plan\n")
a <- detectar_anomalias(mod, d)
ctrl <- read.csv(file.path(ORIGEN, "salidas", "control_pedidos_atipicos_inyectados.csv"))$id_pedido
ok(mean(ctrl %in% a$id_pedido) >= 0.6 && nrow(a) < 60, sprintf("detecta %d de %d pedidos atípicos inyectados (%d marcados en total)", sum(ctrl %in% a$id_pedido), length(ctrl), nrow(a)))
pl <- plan_oportunidades(mod, d)
ok(nrow(pl) > 100 && all(pl$importe_incremental > 0), sprintf("plan de oportunidades: %d sugerencias con importe positivo", nrow(pl)))

cat("6. Ventana de análisis desde / hasta\n")
dv <- leer_datos(list(desde = "2025-07-01", hasta = "2026-06-30"))
ok(min(dv$pedidos$fecha) >= as.Date("2025-07-01") && max(dv$pedidos$fecha) <= as.Date("2026-06-30"), "los pedidos respetan la ventana")
mv <- entrenar(dv, PARAMS_DEFECTO, "completo")
ok(mv$filas < mod$filas && nrow(recomendar(mv, dv, "CLI-0040")$cross_selling) > 0, sprintf("entrena y recomienda dentro de la ventana (%d filas)", mv$filas))
ok(inherits(try(entrenar(leer_datos(list(desde = "2030-01-01")), PARAMS_DEFECTO), silent = TRUE), "try-error"), "ventana sin pedidos: error claro")

cat("7. Retroalimentación\n")
writeLines(c("SKU;Nombre;Familia;Sub Familia;Precio Lista", "QUI-099;Desinfectante ecológico 5 L;Químicos de limpieza;Desinfectantes;22000", "QUI-001;Repetido;x;y;1"), file.path(BASE_DIR, "datos", "entrada", "productos_nov.csv"))
writeLines(c("ID Cliente,Razón Social,Tipo,Segmento", "CLI-0500,Laboratorio Nuevo,Externo,Farmacéutica", "CLI-0501,Sin segmento,Externo,"), file.path(BASE_DIR, "datos", "entrada", "clientes_nov.csv"))
writeLines(c("id_pedido,fecha,id_cliente,sku,cantidad", "PED-900001,2026-10-30,CLI-0500,QUI-099,4", "PED-900001,2026-10-30,CLI-0500,HIG-003,2",
             "PED-900002,2026-10-30,CLI-9999,QUI-099,4", "PED-900003,30/10/2026,CLI-0500,QUI-099,4", "PED-900004,2026-10-30,CLI-0500,QUI-099,0"), file.path(BASE_DIR, "datos", "entrada", "pedidos_nov.csv"))
log <- suppressMessages(procesar_entrada())
ok(identical(log$filas_nuevas, c(1L, 1L, 2L)) && identical(log$rechazadas, c(0L, 1L, 3L)), "ingesta: 1 producto, 1 cliente y 2 líneas nuevas; rechaza cliente sin segmento, cliente inexistente, fecha mal escrita y cantidad cero")
ok(length(list.files(file.path(BASE_DIR, "datos", "entrada"))) == 0 && length(list.files(file.path(BASE_DIR, "datos", "procesados"))) == 3, "los archivos pasan a datos/procesados")
d2 <- leer_datos()
ok(nrow(validar_datos(d2)[validar_datos(d2)$nivel == "error", ]) == 0, "la base sigue íntegra después de la carga")
guardar_modelo(mod); m2 <- asegurar_modelo(d2)
ok(m2$modo == "actualizar" && all(c("QUI-099", "SEG:Farmacéutica") %in% nombres_modelo(m2)) && all(is.finite(m2$rbms[[1]]$W)), "actualización en caliente: incorpora el producto y el segmento nuevos")
ok(nrow(recomendar(m2, d2, "CLI-0500")$cross_selling) > 0, "recomienda al cliente nuevo de un segmento nuevo")
ok(identical(asegurar_modelo(d2)$fecha, m2$fecha), "sin cambios en los datos no reentrena")
ok(suppressMessages(procesar_entrada()) |> nrow() == 0, "carpeta de entrada vacía: no hace nada")

cat("\nTODAS LAS PRUEBAS R OK\n")
