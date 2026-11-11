# =====================================================================
#  ejecutar.R — Corrida completa del recomendador desde R (sin tablero)
#
#  Uso:  Rscript R/ejecutar.R [--desde=AAAA-MM-DD] [--hasta=AAAA-MM-DD]
#                             [--completo] [--afinar]
#
#  1) incorpora lo que haya en datos/entrada
#  2) valida las tres tablas
#  3) entrena o actualiza el modelo para la ventana pedida
#  4) deja en salidas/ el plan de oportunidades y los pedidos atípicos
#
#  El uso diario es el tablero HTML (www/index.html), que trae el mismo
#  motor adentro. Este script sirve para auditar, programar corridas o
#  trabajar con volúmenes grandes.
# =====================================================================
args_todos <- commandArgs(trailingOnly = FALSE)
archivo <- sub("^--file=", "", args_todos[grepl("^--file=", args_todos)])
BASE_DIR <- if (length(archivo)) normalizePath(file.path(dirname(archivo), "..")) else getwd()
args <- commandArgs(trailingOnly = TRUE)
valor <- function(nombre) { x <- sub(paste0("^--", nombre, "="), "", args[grepl(paste0("^--", nombre, "="), args)]); if (length(x)) x[1] else "" }

source(file.path(BASE_DIR, "R", "rbm_core.R"), encoding = "UTF-8")
source(file.path(BASE_DIR, "R", "pipeline.R"), encoding = "UTF-8")

log <- procesar_entrada()
if (nrow(log)) { message("Archivos incorporados:"); print(log) }

d <- leer_datos(list(desde = valor("desde"), hasta = valor("hasta")))
cal <- validar_datos(d)
if (nrow(cal)) { message("Control de calidad:"); print(cal, row.names = FALSE) }
if (any(cal$nivel == "error")) stop("Hay errores en los datos. Corrija las tablas y vuelva a ejecutar.")

mod <- cargar_modelo()
if ("--afinar" %in% args) {
  p <- afinar(d, if (is.null(mod)) PARAMS_DEFECTO else mod$params); print(attr(p, "grilla")); attr(p, "grilla") <- NULL
  mod <- entrenar(d, p, "completo"); mod$actualizaciones <- 0; guardar_modelo(mod)
} else mod <- asegurar_modelo(d, mod, forzar = if ("--completo" %in% args) "completo" else NULL)

met <- mod$metricas
message(sprintf("Modelo %s (%s): %d filas, %d SKU, %d RBM de %d unidades ocultas.", mod$fecha, mod$modo, mod$filas, length(mod$skus), length(mod$rbms), ncol(mod$rbms[[1]]$W)))
if (!is.null(met) && !is.na(met$hit5_rbm))
  message(sprintf("Acierto top 5: RBM %.1f%% vs. más vendido del segmento %.1f%% | Cobertura top 10: %.1f%% vs. %.1f%%",
                  100 * met$hit5_rbm, 100 * met$hit5_base, 100 * met$recall10_rbm, 100 * met$recall10_base))

dir.create(file.path(BASE_DIR, "salidas"), showWarnings = FALSE)
hoy <- format(Sys.Date(), "%Y%m%d")
write.csv(plan_oportunidades(mod, d), file.path(BASE_DIR, "salidas", paste0("plan_oportunidades_", hoy, ".csv")), row.names = FALSE, fileEncoding = "UTF-8")
write.csv(detectar_anomalias(mod, d), file.path(BASE_DIR, "salidas", paste0("pedidos_atipicos_", hoy, ".csv")), row.names = FALSE, fileEncoding = "UTF-8")
message("Listo. Resultados en la carpeta salidas/")
