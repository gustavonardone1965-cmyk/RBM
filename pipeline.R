# =====================================================================
#  pipeline.R — Lógica de negocio del recomendador RBM de Compras
#  Espejo en R del motor que corre dentro del tablero HTML.
#  Lee las 3 tablas, aplica la ventana de análisis (desde / hasta),
#  arma la matriz cliente x producto, entrena un conjunto de RBM,
#  evalúa, recomienda (reposición / upselling / cross-selling /
#  novedades, con motivos) y detecta pedidos atípicos.
# =====================================================================

PARAMS_DEFECTO <- list(ocultas = 8, epocas = 300, tasa = 0.05, lote = 16,
                       decaimiento = 2e-4, k = 1, n_modelos = 3,
                       ventana_meses = 6, perfil_meses = 12,
                       epocas_actualizacion = 120, dias_novedad = 120,
                       umbral_atipico = 0.05, umbral_reco = 0.7)

ruta <- function(...) file.path(BASE_DIR, ...)

# Suma meses respetando fin de mes (31/10 - 6 meses = 30/04)
sumar_meses <- function(f, n) {
  lt <- as.POSIXlt(as.Date(f))
  m  <- lt$mon + n
  y  <- lt$year + 1900 + m %/% 12
  m  <- m %% 12
  primero_sig <- as.Date(sprintf("%04d-%02d-01", ifelse(m == 11, y + 1, y), ifelse(m == 11, 1, m + 2)))
  ult <- as.integer(format(primero_sig - 1, "%d"))
  as.Date(sprintf("%04d-%02d-%02d", y, m + 1, pmin(lt$mday, ult)))
}

# ---------------------------------------------------------------- datos
# Las bases son los tres Excel de datos/: productos.xlsx, clientes.xlsx y
# pedidos.xlsx (una hoja cada uno). Requiere el paquete readxl; si en su
# lugar hay un .csv con el mismo nombre, también se lee.
requiere_readxl <- function() {
  if (!requireNamespace("readxl", quietly = TRUE))
    stop("Para leer los Excel instale el paquete: install.packages(\"readxl\")", call. = FALSE)
}

leer_excel <- function(archivo) {
  requiere_readxl()
  df <- as.data.frame(readxl::read_excel(archivo, sheet = 1, guess_max = 100000), stringsAsFactors = FALSE)
  names(df) <- normalizar_nombres(names(df))
  df <- df[, !is.na(names(df)) & nzchar(names(df)), drop = FALSE]
  for (col in names(df)) {
    v <- df[[col]]
    if (inherits(v, c("POSIXct", "POSIXt", "Date"))) df[[col]] <- format(as.Date(v), "%Y-%m-%d")
    else if (is.character(v)) df[[col]] <- trimws(v)
  }
  df[rowSums(!is.na(df) & df != "") > 0, , drop = FALSE]
}

leer_tabla <- function(nombre) {
  xlsx <- ruta("datos", paste0(nombre, ".xlsx")); csv <- ruta("datos", paste0(nombre, ".csv"))
  df <- if (file.exists(xlsx)) leer_excel(xlsx)
        else if (file.exists(csv)) read.csv(csv, stringsAsFactors = FALSE, fileEncoding = "UTF-8", check.names = FALSE, na.strings = c("", "NA"))
        else stop("No se encontró datos/", nombre, ".xlsx", call. = FALSE)
  names(df) <- normalizar_nombres(names(df))
  esperadas <- COLUMNAS[[nombre]]
  for (f in setdiff(esperadas, names(df))) df[[f]] <- NA
  df <- df[, esperadas, drop = FALSE]
  for (f in intersect(c("fecha", "fecha_alta"), names(df))) df[[f]] <- normalizar_fecha(df[[f]])
  for (f in intersect(c("id_cliente", "sku", "id_pedido", "sku_superior"), names(df))) df[[f]] <- as.character(df[[f]])
  for (f in intersect(c("cantidad", "precio_unitario", "precio_lista"), names(df))) df[[f]] <- suppressWarnings(as.numeric(df[[f]]))
  for (f in names(df)) if (is.character(df[[f]])) df[[f]][!nzchar(trimws(df[[f]]))] <- NA
  df
}

# Escribe las tres bases de vuelta a Excel (o a CSV si falta writexl)
guardar_tabla <- function(nombre, df) {
  if (requireNamespace("writexl", quietly = TRUE)) writexl::write_xlsx(setNames(list(df), nombre), ruta("datos", paste0(nombre, ".xlsx")))
  else write.csv(df, ruta("datos", paste0(nombre, ".csv")), row.names = FALSE, fileEncoding = "UTF-8", na = "")
}

# Fechas como vengan de una planilla: AAAA-MM-DD, DD/MM/AAAA o número de serie de Excel
normalizar_fecha <- function(x) {
  s <- trimws(as.character(x)); out <- rep(NA_character_, length(s))
  iso <- grepl("^\\d{4}-\\d{1,2}-\\d{1,2}", s); out[iso] <- format(as.Date(substr(s[iso], 1, 10)), "%Y-%m-%d")
  lat <- !iso & grepl("^\\d{1,2}[/.-]\\d{1,2}[/.-]\\d{4}$", s)
  out[lat] <- format(as.Date(s[lat], tryFormats = c("%d/%m/%Y", "%d-%m-%Y", "%d.%m.%Y")), "%Y-%m-%d")
  ser <- !iso & !lat & grepl("^\\d{5}(\\.\\d+)?$", s)
  out[ser] <- format(as.Date(round(as.numeric(s[ser])), origin = "1899-12-30"), "%Y-%m-%d")
  resto <- !iso & !lat & !ser & nzchar(s) & s != "NA"; out[resto] <- s[resto]
  out
}

COLUMNAS <- list(
  clientes  = c("id_cliente", "razon_social", "tipo", "segmento", "provincia", "pais", "tamano", "fecha_alta"),
  productos = c("sku", "nombre", "familia", "subfamilia", "unidad", "gama", "tipo_item", "precio_lista", "sku_superior", "fecha_alta", "activo"),
  pedidos   = c("id_pedido", "fecha", "id_cliente", "sku", "cantidad", "precio_unitario", "canal"))

# rango = list(desde = "AAAA-MM-DD", hasta = "AAAA-MM-DD"), ambos opcionales e inclusivos
leer_datos <- function(rango = list()) {
  d <- list(clientes = leer_tabla("clientes"), productos = leer_tabla("productos"),
            todos = leer_tabla("pedidos"))
  d$productos$sku_superior[is.na(d$productos$sku_superior)] <- ""
  d$productos$activo[is.na(d$productos$activo)] <- "Sí"
  d$todos$fecha <- as.Date(d$todos$fecha)
  d$todos <- d$todos[!is.na(d$todos$id_pedido) & !is.na(d$todos$sku), ]
  aplicar_rango(d, rango)
}

aplicar_rango <- function(d, rango = list()) {
  desde <- if (is.null(rango$desde) || !nzchar(rango$desde)) "" else as.character(rango$desde)
  hasta <- if (is.null(rango$hasta) || !nzchar(rango$hasta)) "" else as.character(rango$hasta)
  p <- d$todos
  if (nzchar(desde)) p <- p[p$fecha >= as.Date(desde), ]
  if (nzchar(hasta)) p <- p[p$fecha <= as.Date(hasta), ]
  d$pedidos <- p
  d$rango <- list(desde = desde, hasta = hasta)
  d
}

es_activo <- function(x) !toupper(substr(trimws(as.character(x)), 1, 1)) %in% c("N", "F", "0")

ctx_nombres <- function(d) c(paste0("TIPO:", sort(unique(d$clientes$tipo))),
                             paste0("SEG:",  sort(unique(d$clientes$segmento))))

# Vector de entrada: 1 en los SKU activos y en el tipo/segmento del cliente
vector_entrada <- function(nombres, skus_activos, tipo, segmento) {
  v <- setNames(rep(0, length(nombres)), nombres)
  v[intersect(c(skus_activos, paste0("TIPO:", tipo), paste0("SEG:", segmento)), nombres)] <- 1
  v
}

firma_datos <- function(d) paste(nrow(d$clientes), nrow(d$productos), nrow(d$pedidos),
                                 if (nrow(d$pedidos)) as.character(max(d$pedidos$fecha)) else "",
                                 d$rango$desde, d$rango$hasta, sep = "|")

# ---------------------------------------------------- control de calidad
validar_datos <- function(d) {
  out <- data.frame(nivel = character(), texto = character(), stringsAsFactors = FALSE)
  add <- function(nivel, n, texto) if (n > 0) {
    t <- sub("^%d ", "", texto)
    out[nrow(out) + 1, ] <<- list(nivel, if (t == texto) sub(" \\(%d\\)$", "", texto) else paste0(toupper(substr(t, 1, 1)), substring(t, 2), ": ", n))
  }
  add("error", sum(duplicated(d$clientes$id_cliente)), "%d clientes con código repetido")
  add("error", sum(duplicated(d$productos$sku)), "%d productos con SKU repetido")
  add("error", sum(duplicated(d$todos[c("id_pedido", "sku")])), "%d líneas de pedido repetidas (mismo pedido y SKU)")
  add("error", sum(!d$todos$id_cliente %in% d$clientes$id_cliente), "%d líneas con cliente inexistente")
  add("error", sum(!d$todos$sku %in% d$productos$sku), "%d líneas con SKU inexistente")
  add("error", sum(is.na(d$todos$fecha)), "%d líneas con fecha inválida")
  add("error", sum(is.na(d$todos$cantidad) | d$todos$cantidad <= 0), "%d líneas con cantidad cero o negativa")
  add("aviso", sum(is.na(d$productos$precio_lista) | d$productos$precio_lista <= 0), "%d productos sin precio de lista")
  add("error", sum(nzchar(d$productos$sku_superior) & !d$productos$sku_superior %in% d$productos$sku), "%d productos con sku_superior inexistente")
  add("error", sum(is.na(d$clientes$tipo) | is.na(d$clientes$segmento)), "%d clientes sin tipo o segmento")
  add("aviso", sum(!d$clientes$id_cliente %in% d$pedidos$id_cliente), "%d clientes sin pedidos en la ventana de análisis (se recomiendan por tipo y segmento)")
  add("aviso", sum(!d$productos$sku %in% d$pedidos$sku), "%d productos sin ventas en la ventana de análisis")
  if (!nrow(d$pedidos)) add("error", 1, "No hay pedidos en la ventana de análisis (%d)")
  else if (sumar_meses(min(d$pedidos$fecha), 6) > max(d$pedidos$fecha))
    add("aviso", 1, "La ventana de análisis tiene menos de 6 meses: el modelo aprende con pocas filas (%d)")
  out
}

# --------------------------------------------- matriz de entrenamiento
# Una fila por cliente y ventana móvil (ventana_meses, paso 3 meses, hasta
# 9 cortes hacia atrás): 1 si el cliente compró el SKU en esa ventana.
# Se agregan unidades de contexto (tipo y segmento) para el arranque en frío.
construir_matriz <- function(d, ventana_meses = 6, ocultar = NULL) {
  skus <- d$productos$sku
  nombres <- c(skus, ctx_nombres(d))
  ped <- d$pedidos
  if (!nrow(ped)) stop("No hay pedidos en la ventana de análisis elegida.")
  fin <- max(ped$fecha); inicio <- min(ped$fecha)
  if (!is.null(ocultar)) ped <- ped[!paste(ped$id_cliente, ped$sku) %in% ocultar, ]
  filas <- list()
  for (q in 0:8) {
    corte <- sumar_meses(fin, -3 * q)
    if (q > 0 && corte < inicio) break
    ini <- sumar_meses(corte, -ventana_meses)
    sub <- ped[ped$fecha > ini & ped$fecha <= corte & ped$sku %in% skus, c("id_cliente", "sku")]
    if (!nrow(sub)) next
    for (id in unique(sub$id_cliente)) {
      cl <- d$clientes[match(id, d$clientes$id_cliente), ]
      if (is.na(cl$id_cliente)) next
      filas[[length(filas) + 1]] <- vector_entrada(nombres, unique(sub$sku[sub$id_cliente == id]), cl$tipo, cl$segmento)
    }
  }
  X <- do.call(rbind, filas)
  colnames(X) <- nombres
  X
}

# Perfil reciente del cliente: en qué proporción de sus pedidos aparece cada SKU
perfil_cliente <- function(d, id, meses = 12) {
  frec <- setNames(rep(0, nrow(d$productos)), d$productos$sku)
  if (!nrow(d$pedidos)) return(frec)
  ini <- sumar_meses(max(d$pedidos$fecha), -meses)
  p <- d$pedidos[d$pedidos$id_cliente == id & d$pedidos$fecha > ini & d$pedidos$sku %in% names(frec), ]
  n_ped <- length(unique(p$id_pedido))
  if (n_ped) {
    t <- tapply(p$id_pedido, p$sku, function(x) length(unique(x))) / n_ped
    frec[names(t)] <- t
  }
  frec
}

# --------------------------------------------------- conjunto de RBM
entrenar_conjunto <- function(X, p, semilla = 2026) {
  lapply(seq_len(max(1, p$n_modelos)), function(k) {
    m <- rbm_iniciar(colnames(X), p$ocultas, X, semilla + k - 1)
    rbm_entrenar(m, X, p$epocas, p$tasa, p$lote, decaimiento = p$decaimiento, k = p$k, semilla = semilla + k - 1)
  })
}

# Probabilidad media de cada unidad visible sobre el conjunto
puntuar <- function(mod, V) {
  Reduce(`+`, lapply(mod$rbms, function(m) rbm_reconstruir(m, V))) / length(mod$rbms)
}

nombres_modelo <- function(mod) rownames(mod$rbms[[1]]$W)

# ---------------------------------------------------------- evaluación
# Oculta ~20% de los productos de cada cliente (mín. 1), entrena sin ellos
# y mide si el modelo los vuelve a "descubrir" en su top-N. Línea de base:
# recomendar lo más vendido del segmento.
evaluar <- function(d, p) {
  set.seed(7)
  ocultos <- list()
  for (id in unique(d$pedidos$id_cliente)) {
    pf <- perfil_cliente(d, id, p$perfil_meses)
    tiene <- names(pf)[pf > 0]
    if (length(tiene) < 5) next
    ocultos[[id]] <- sample(tiene, max(1, round(length(tiene) * 0.2)))
  }
  vacio <- list(clientes_evaluados = 0, hit5_rbm = NA, recall10_rbm = NA, hit5_base = NA, recall10_base = NA)
  if (!length(ocultos)) return(vacio)
  claves <- unlist(lapply(names(ocultos), function(id) paste(id, ocultos[[id]])))
  X  <- construir_matriz(d, p$ventana_meses, ocultar = claves)
  m  <- list(rbms = entrenar_conjunto(X, p))
  d2 <- d; d2$pedidos <- d2$pedidos[!paste(d2$pedidos$id_cliente, d2$pedidos$sku) %in% claves, ]
  seg_de <- setNames(d$clientes$segmento, d$clientes$id_cliente)
  pares <- unique(d2$pedidos[c("id_cliente", "sku")])
  pop <- tapply(pares$sku, seg_de[pares$id_cliente], table)
  r <- t(sapply(names(ocultos), function(id) {
    pf <- perfil_cliente(d2, id, p$perfil_meses)
    cl <- d$clientes[d$clientes$id_cliente == id, ]
    s  <- puntuar(m, vector_entrada(colnames(X), names(pf)[pf > 0], cl$tipo, cl$segmento))[1, names(pf)]
    s[pf > 0] <- -Inf
    top <- names(sort(s, decreasing = TRUE))[1:10]
    pp <- pop[[cl$segmento]]; pp <- pp[!names(pp) %in% names(pf)[pf > 0]]
    topb <- names(sort(pp, decreasing = TRUE))[1:10]
    h <- ocultos[[id]]
    c(any(h %in% top[1:5]), mean(h %in% top), any(h %in% topb[1:5]), mean(h %in% topb))
  }))
  list(clientes_evaluados = nrow(r), hit5_rbm = mean(r[, 1]), recall10_rbm = mean(r[, 2]),
       hit5_base = mean(r[, 3]), recall10_base = mean(r[, 4]))
}

# --------------------------------------------------------- entrenamiento
# modo "completo": arranca de cero. modo "actualizar": conserva lo aprendido,
# agrega unidades para productos/segmentos nuevos y afina con menos épocas.
entrenar <- function(d, p = PARAMS_DEFECTO, modo = c("completo", "actualizar"),
                     modelo_previo = NULL, evaluar_modelo = TRUE) {
  modo <- match.arg(modo)
  t0 <- Sys.time()
  X <- construir_matriz(d, p$ventana_meses)
  if (modo == "actualizar" && !is.null(modelo_previo) && length(modelo_previo$rbms)) {
    rbms <- lapply(seq_along(modelo_previo$rbms), function(k) {
      m <- rbm_expandir(modelo_previo$rbms[[k]], colnames(X), X)
      rbm_entrenar(m, X, p$epocas_actualizacion, p$tasa * 0.5, p$lote,
                   decaimiento = p$decaimiento, k = p$k, semilla = 500 + k + nrow(X))
    })
    met <- if (evaluar_modelo) evaluar(d, p) else modelo_previo$metricas
  } else {
    modo <- "completo"
    rbms <- entrenar_conjunto(X, p)
    met  <- if (evaluar_modelo) evaluar(d, p) else NULL
  }
  list(rbms = rbms, params = p, metricas = met, modo = modo,
       fecha = format(Sys.time(), "%Y-%m-%d %H:%M:%S"), rango = d$rango,
       segundos = round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1),
       filas = nrow(X), skus = d$productos$sku, firma = firma_datos(d))
}

# Prueba varias cantidades de unidades ocultas y se queda con la que mejor
# "redescubre" productos ocultos.
afinar <- function(d, p = PARAMS_DEFECTO, candidatos = c(4, 8, 16, 24)) {
  res <- sapply(candidatos, function(h) { q <- p; q$ocultas <- h; m <- evaluar(d, q); m$hit5_rbm + m$recall10_rbm / 10 })
  p$ocultas <- candidatos[which.max(res)]
  attr(p, "grilla") <- data.frame(ocultas = candidatos, puntaje = round(res, 3))
  p
}

# ------------------------------------------------------- recomendación
# Motivos: productos del cliente cuya ausencia más baja la probabilidad
# del candidato (los dos que más pesan).
motivos <- function(mod, v, candidatos, skus) {
  act <- intersect(names(v)[v > 0], skus)
  res <- setNames(rep("", length(candidatos)), candidatos)
  if (!length(act) || !length(candidatos)) return(res)
  base <- puntuar(mod, v)[1, candidatos]
  V <- matrix(v, nrow = length(act), ncol = length(v), byrow = TRUE, dimnames = list(act, names(v)))
  V[cbind(seq_along(act), match(act, names(v)))] <- 0
  caida <- matrix(base, nrow = length(act), ncol = length(candidatos), byrow = TRUE) - puntuar(mod, V)[, candidatos, drop = FALSE]
  for (j in seq_along(candidatos)) {
    o <- order(-caida[, j])[seq_len(min(2, length(act)))]
    res[j] <- paste(act[o][caida[o, j] > 0.01], collapse = ", ")
  }
  res
}

recomendar <- function(mod, d, id_cliente = NULL, canasta = character(0),
                       tipo = NULL, segmento = NULL, k = 6) {
  pr <- d$productos
  cl <- if (!is.null(id_cliente) && id_cliente %in% d$clientes$id_cliente)
          d$clientes[d$clientes$id_cliente == id_cliente, ] else NULL
  tipo <- if (!is.null(cl)) cl$tipo else tipo
  segmento <- if (!is.null(cl)) cl$segmento else segmento
  pf <- if (!is.null(cl)) perfil_cliente(d, cl$id_cliente, mod$params$perfil_meses)
        else setNames(rep(0, nrow(pr)), pr$sku)
  canasta <- intersect(canasta, pr$sku)
  usa <- unique(c(names(pf)[pf > 0], canasta))
  vv  <- vector_entrada(nombres_modelo(mod), usa, tipo, segmento)
  s   <- puntuar(mod, vv)[1, ]
  s   <- s[intersect(names(s), pr$sku)]
  seg_de <- setNames(d$clientes$segmento, d$clientes$id_cliente)
  pseg <- d$pedidos[seg_de[d$pedidos$id_cliente] %in% segmento, ]
  qtip <- tapply(pseg$cantidad, pseg$sku, median)
  qde  <- function(sku) { q <- round(qtip[sku]); unname(ifelse(is.na(q) | q < 1, 1, q)) }
  info <- function(sku) pr[match(sku, pr$sku), ]
  vigentes <- pr$sku[es_activo(pr$activo)]
  umbral <- if (is.null(mod$params$umbral_reco)) 0 else mod$params$umbral_reco   # sólo se proponen productos con afinidad >= umbral
  ref <- unique(c(canasta, names(pf)[pf > 0]))

  # Reposición: habituales (>= 30% de sus pedidos) que faltan en el pedido actual
  repo <- names(sort(pf[pf >= 0.3 & !names(pf) %in% canasta], decreasing = TRUE))
  repo <- head(repo, k)
  reposicion <- data.frame(sku = repo, frecuencia = round(unname(pf[repo]), 2), stringsAsFactors = FALSE)

  # Upselling: sku_superior o Premium de la misma subfamilia, más caro, que no usa
  up <- list()
  for (r in ref) {
    base <- info(r)
    cand <- pr[((pr$sku == base$sku_superior) |
                (pr$subfamilia == base$subfamilia & pr$gama == "Premium" & base$gama != "Premium")) &
               pr$precio_lista > base$precio_lista & pr$sku %in% vigentes &
               !pr$sku %in% usa & pr$sku %in% names(s), ]
    if (!nrow(cand)) next
    q <- qde(r)
    up[[length(up) + 1]] <- data.frame(sku = cand$sku, reemplaza = r, score = unname(s[cand$sku]),
      cantidad = q, incremental = (cand$precio_lista - base$precio_lista) * q, stringsAsFactors = FALSE)
  }
  up <- if (length(up)) do.call(rbind, up) else data.frame(sku = character(), reemplaza = character(),
          score = numeric(), cantidad = numeric(), incremental = numeric(), stringsAsFactors = FALSE)
  up <- up[order(-up$score), ]; up <- up[!duplicated(up$sku), ]
  descartadas <- sum(up$score < umbral)
  up <- head(up[up$score >= umbral, , drop = FALSE], k)

  # Cross-selling: subfamilias que el cliente todavía no cubre; una sugerencia por subfamilia
  subs_ref <- unique(c(info(ref)$subfamilia, info(up$sku)$subfamilia))
  nuevos <- pr$sku[as.Date(pr$fecha_alta) > max(d$pedidos$fecha) - mod$params$dias_novedad]
  cs <- s[names(s) %in% vigentes & !names(s) %in% usa & !names(s) %in% up$sku &
          !names(s) %in% nuevos & !info(names(s))$subfamilia %in% subs_ref]
  cs <- sort(cs, decreasing = TRUE)
  cs <- cs[!duplicated(info(names(cs))$subfamilia)]
  descartadas <- descartadas + sum(cs < umbral)
  cs <- head(cs[cs >= umbral], k)
  cross <- data.frame(sku = names(cs), score = as.numeric(cs), cantidad = qde(names(cs)), stringsAsFactors = FALSE)
  cross$incremental <- cross$cantidad * info(cross$sku)$precio_lista

  # Novedades: productos recién incorporados, ordenados por el puntaje del modelo
  nv <- s[names(s) %in% intersect(nuevos, vigentes) & !names(s) %in% usa & !names(s) %in% up$sku]
  nv <- head(sort(nv, decreasing = TRUE), 3)
  nov <- data.frame(sku = names(nv), score = as.numeric(nv), stringsAsFactors = FALSE)

  mot <- motivos(mod, vv, c(up$sku, cross$sku, nov$sku), pr$sku)
  dec <- function(df, con_motivo = TRUE) {
    extra <- info(df$sku)[, c("nombre", "familia", "subfamilia", "gama", "precio_lista")]
    if (!nrow(df)) extra <- extra[0, ]
    rownames(df) <- NULL; rownames(extra) <- NULL
    out <- cbind(df, extra)
    if (con_motivo) out$motivo <- unname(mot[df$sku])
    out
  }
  list(cliente = if (!is.null(cl)) as.list(cl) else list(tipo = tipo, segmento = segmento, razon_social = "Cliente nuevo"),
       reposicion = dec(reposicion, FALSE), upselling = dec(up), cross_selling = dec(cross), novedades = dec(nov),
       umbral = umbral, descartadas = descartadas)
}

# ------------------------------------------------- pedidos atípicos
# Para cada pedido del período del perfil, compara sus productos contra lo que
# el modelo espera del cliente (perfil sin ese pedido). Marca productos con
# probabilidad menor al umbral y cantidades fuera de rango (z > 3 sobre log).
detectar_anomalias <- function(mod, d, umbral = mod$params$umbral_atipico) {
  fin <- max(d$pedidos$fecha)
  ped <- d$pedidos[d$pedidos$fecha > sumar_meses(fin, -mod$params$perfil_meses), ]
  nombres <- nombres_modelo(mod)
  novedad <- d$productos$sku[as.Date(d$productos$fecha_alta) > fin - mod$params$dias_novedad]
  lq <- log1p(d$pedidos$cantidad); key <- paste(d$pedidos$id_cliente, d$pedidos$sku)
  mu <- tapply(lq, key, mean); sdv <- tapply(lq, key, sd)
  res <- list()
  for (id in unique(ped$id_cliente)) {
    cl <- d$clientes[match(id, d$clientes$id_cliente), ]
    if (is.na(cl$id_cliente)) next
    pc <- ped[ped$id_cliente == id, ]
    tot <- table(pc$sku)
    for (pid in unique(pc$id_pedido)) {
      lin <- pc[pc$id_pedido == pid, ]
      otros <- names(tot)[tot - table(factor(lin$sku, levels = names(tot))) > 0]
      pv <- puntuar(mod, vector_entrada(nombres, otros, cl$tipo, cl$segmento))[1, ]
      p_it <- pv[lin$sku]; p_it[is.na(p_it)] <- 0.5
      raros <- lin$sku[p_it < umbral & !lin$sku %in% otros & !lin$sku %in% novedad]
      z <- (log1p(lin$cantidad) - mu[paste(id, lin$sku)]) / sdv[paste(id, lin$sku)]
      qraras <- lin$sku[is.finite(z) & z > 3]
      if (length(raros) || length(qraras)) {
        res[[length(res) + 1]] <- data.frame(id_pedido = pid, fecha = as.character(lin$fecha[1]),
          id_cliente = id, razon_social = cl$razon_social, segmento = cl$segmento,
          puntaje = round(mean(-log(pmax(p_it, 1e-4))), 2),
          productos_inusuales = paste(raros, collapse = ", "),
          cantidades_inusuales = paste(qraras, collapse = ", "),
          importe = sum(lin$cantidad * lin$precio_unitario), stringsAsFactors = FALSE)
      }
    }
  }
  if (!length(res)) return(data.frame())
  out <- do.call(rbind, res); out <- out[order(-out$puntaje), ]; rownames(out) <- NULL; out
}

# ------------------------------------- plan de oportunidades (lote)
plan_oportunidades <- function(mod, d, k = 3) {
  out <- list()
  for (id in d$clientes$id_cliente) {
    r <- recomendar(mod, d, id, k = k)
    for (tipo in c("upselling", "cross_selling")) {
      df <- r[[tipo]]; if (!nrow(df)) next
      out[[length(out) + 1]] <- data.frame(id_cliente = id, razon_social = r$cliente$razon_social,
        tipo_cliente = r$cliente$tipo, segmento = r$cliente$segmento,
        oportunidad = ifelse(tipo == "upselling", "Upselling", "Cross-selling"),
        sku = df$sku, producto = df$nombre, score = round(df$score, 3),
        cantidad_sugerida = df$cantidad, importe_incremental = round(df$incremental),
        motivo = ifelse(is.na(df$motivo), "", df$motivo), stringsAsFactors = FALSE)
    }
  }
  do.call(rbind, out)
}

# ------------------------------------------------ ingesta automática
# Toma los CSV/XLSX que se dejan en datos/entrada/. El nombre del archivo
# debe contener "pedidos", "clientes" o "productos". Valida, agrega,
# elimina duplicados y mueve el archivo a datos/procesados/.
CLAVES <- list(clientes = "id_cliente", productos = "sku", pedidos = c("id_pedido", "sku"))

# Encabezados tolerantes: sin acentos, minúsculas, y sinónimos habituales de un ERP
ALIAS <- c(sub_familia = "subfamilia", precio = "precio_lista", descripcion = "nombre", producto = "nombre",
           nro_pedido = "id_pedido", numero_pedido = "id_pedido", pedido = "id_pedido", orden = "id_pedido",
           cod_cliente = "id_cliente", codigo_cliente = "id_cliente", cliente = "id_cliente",
           codigo = "sku", cod_producto = "sku", codigo_producto = "sku", articulo = "sku",
           cant = "cantidad", precio_unit = "precio_unitario", precio_unitario_ = "precio_unitario",
           razon = "razon_social", nombre_cliente = "razon_social", rubro = "segmento", tamanio = "tamano")

normalizar_nombres <- function(x) {
  x <- tolower(trimws(iconv(x, "UTF-8", "ASCII//TRANSLIT")))
  x <- gsub("^_|_$", "", gsub("[^a-z0-9]+", "_", x))
  ifelse(x %in% names(ALIAS), ALIAS[x], x)
}

agregar_filas <- function(tabla, nuevas) {
  actual <- leer_tabla(tabla)
  nuevas <- as.data.frame(nuevas, stringsAsFactors = FALSE)
  for (f in names(nuevas)) if (inherits(nuevas[[f]], c("POSIXct", "POSIXt", "Date"))) nuevas[[f]] <- format(as.Date(nuevas[[f]]), "%Y-%m-%d")
  nn <- normalizar_nombres(names(nuevas)); crudo <- gsub("^_|_$", "", gsub("[^a-z0-9]+", "_", tolower(trimws(iconv(names(nuevas), "UTF-8", "ASCII//TRANSLIT")))))
  dup <- duplicated(nn) | (nn != crudo & nn %in% crudo)          # alias que choca con una columna real
  nn[dup] <- crudo[dup]; names(nuevas) <- nn
  if (any(!CLAVES[[tabla]] %in% names(nuevas)))
    stop("Faltan columnas clave en ", tabla, ": ", paste(setdiff(CLAVES[[tabla]], names(nuevas)), collapse = ", "))
  for (f in setdiff(names(actual), names(nuevas))) nuevas[[f]] <- NA
  nuevas <- nuevas[, names(actual), drop = FALSE]
  fila <- seq_len(nrow(nuevas)) + 1
  rech <- character(0); malo <- rep(FALSE, nrow(nuevas))
  marcar <- function(cond, texto) { cond <- cond & !malo; rech <<- c(rech, sprintf(texto, fila[cond])); malo <<- malo | cond }
  vacio <- function(x) is.na(x) | !nzchar(trimws(as.character(x)))
  if (tabla == "pedidos") {
    cli <- leer_tabla("clientes")$id_cliente; prd <- leer_tabla("productos")
    nuevas$fecha <- normalizar_fecha(nuevas$fecha)
    marcar(!nuevas$id_cliente %in% cli, "Fila %d: el cliente no existe")
    marcar(!nuevas$sku %in% prd$sku, "Fila %d: el SKU no existe")
    marcar(!grepl("^\\d{4}-\\d{2}-\\d{2}$", nuevas$fecha) | is.na(as.Date(nuevas$fecha, optional = TRUE)), "Fila %d: fecha debe ser AAAA-MM-DD")
    nuevas$cantidad <- suppressWarnings(as.numeric(nuevas$cantidad))
    marcar(is.na(nuevas$cantidad) | nuevas$cantidad <= 0, "Fila %d: cantidad debe ser mayor a cero")
    pu <- suppressWarnings(as.numeric(nuevas$precio_unitario)); sin <- is.na(pu) | pu <= 0
    pu[sin] <- prd$precio_lista[match(nuevas$sku[sin], prd$sku)]; nuevas$precio_unitario <- pu
  }
  if (tabla == "productos") {
    marcar(vacio(nuevas$nombre) | vacio(nuevas$subfamilia), "Fila %d: falta nombre o subfamilia")
    nuevas$precio_lista <- suppressWarnings(as.numeric(nuevas$precio_lista)); nuevas$precio_lista[is.na(nuevas$precio_lista)] <- 0
    nuevas$activo[vacio(nuevas$activo)] <- "Sí"; nuevas$gama[vacio(nuevas$gama)] <- "Estándar"
    nuevas$tipo_item[vacio(nuevas$tipo_item)] <- "C"; nuevas$fecha_alta[vacio(nuevas$fecha_alta)] <- format(Sys.Date())
    nuevas$sku_superior[is.na(nuevas$sku_superior)] <- ""
  }
  if (tabla == "clientes") {
    marcar(vacio(nuevas$tipo) | vacio(nuevas$segmento), "Fila %d: falta tipo o segmento")
    nuevas$fecha_alta[vacio(nuevas$fecha_alta)] <- format(Sys.Date()); nuevas$pais[vacio(nuevas$pais)] <- "Argentina"
  }
  k <- CLAVES[[tabla]]
  marcar(Reduce(`|`, lapply(nuevas[k], vacio)), paste0("Fila %d: falta ", paste(k, collapse = " / ")))
  nuevas <- nuevas[!malo, , drop = FALSE]
  ka <- do.call(paste, actual[k]); kn <- do.call(paste, nuevas[k])
  nuevas <- nuevas[!kn %in% ka & !duplicated(kn), , drop = FALSE]
  if (nrow(nuevas)) guardar_tabla(tabla, rbind(actual, nuevas))
  structure(nrow(nuevas), rechazadas = rech)
}

procesar_entrada <- function() {
  dir.create(ruta("datos", "entrada"), showWarnings = FALSE, recursive = TRUE)
  dir.create(ruta("datos", "procesados"), showWarnings = FALSE, recursive = TRUE)
  arch <- list.files(ruta("datos", "entrada"), pattern = "\\.(xlsx|csv)$", full.names = TRUE, ignore.case = TRUE)
  log <- data.frame(archivo = character(), tabla = character(), filas_nuevas = integer(), rechazadas = integer(), stringsAsFactors = FALSE)
  for (tabla in c("productos", "clientes", "pedidos")) {      # el orden importa
    for (f in arch[grepl(tabla, basename(arch), ignore.case = TRUE)]) {
      df <- if (grepl("xlsx$", f, ignore.case = TRUE)) leer_excel(f) else {
        prim <- readLines(f, n = 1, encoding = "UTF-8", warn = FALSE)
        sep <- if (lengths(regmatches(prim, gregexpr(";", prim))) > lengths(regmatches(prim, gregexpr(",", prim)))) ";" else ","
        read.csv(f, sep = sep, stringsAsFactors = FALSE, fileEncoding = "UTF-8-BOM", check.names = FALSE)
      }
      n <- agregar_filas(tabla, df)
      file.rename(f, file.path(ruta("datos", "procesados"), paste0(format(Sys.time(), "%Y%m%d_%H%M%S_"), basename(f))))
      log[nrow(log) + 1, ] <- list(basename(f), tabla, as.integer(n), length(attr(n, "rechazadas")))
      if (length(attr(n, "rechazadas"))) message(basename(f), ": ", paste(attr(n, "rechazadas"), collapse = "; "))
    }
  }
  log
}

# ------------------------------------------------ persistencia
guardar_modelo <- function(mod) {
  dir.create(ruta("modelo"), showWarnings = FALSE)
  saveRDS(mod, ruta("modelo", "rbm_modelo.rds"))
  met <- mod$metricas
  h <- data.frame(fecha = mod$fecha, modo = mod$modo, desde = mod$rango$desde, hasta = mod$rango$hasta,
                  filas = mod$filas, skus = length(mod$skus), modelos = length(mod$rbms), segundos = mod$segundos,
                  umbral_reco = mod$params$umbral_reco,
                  hit5_rbm = if (is.null(met)) NA else round(met$hit5_rbm, 3),
                  hit5_base = if (is.null(met)) NA else round(met$hit5_base, 3),
                  recall10_rbm = if (is.null(met)) NA else round(met$recall10_rbm, 3),
                  recall10_base = if (is.null(met)) NA else round(met$recall10_base, 3))
  f <- ruta("modelo", "historial_entrenamientos.csv")
  write.table(h, f, sep = ",", row.names = FALSE, col.names = !file.exists(f), append = file.exists(f),
              fileEncoding = "UTF-8")
}

cargar_modelo <- function() {
  f <- ruta("modelo", "rbm_modelo.rds")
  if (file.exists(f)) readRDS(f) else NULL
}

# Decide solo: sin modelo -> completo; datos o ventana distintos -> actualización
# en caliente; cada 10 actualizaciones seguidas -> reentrenamiento completo.
asegurar_modelo <- function(d, mod = cargar_modelo(), forzar = NULL) {
  if (is.null(mod) || is.null(mod$rbms)) {
    mod <- entrenar(d, PARAMS_DEFECTO, "completo"); mod$actualizaciones <- 0
  } else if (!is.null(forzar) || !identical(mod$firma, firma_datos(d))) {
    cambio_ventana <- !identical(mod$rango, d$rango)
    seguidas <- if (is.null(mod$actualizaciones)) 0 else mod$actualizaciones
    modo <- if (!is.null(forzar)) forzar else if (cambio_ventana || seguidas >= 10) "completo" else "actualizar"
    mod <- entrenar(d, mod$params, modo, mod)
    mod$actualizaciones <- if (mod$modo == "completo") 0 else seguidas + 1
  } else return(mod)
  guardar_modelo(mod)
  mod
}
