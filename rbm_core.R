# =====================================================================
#  rbm_core.R  —  Restricted Boltzmann Machine (Bernoulli–Bernoulli)
#  Implementación propia en R base, entrenada con Contrastive Divergence
#  (CD-k), momentum y weight decay. No requiere paquetes externos.
#  Consultnet SRL — Recomendador de Compras
# =====================================================================

sigmoide <- function(x) 1 / (1 + exp(-pmax(pmin(x, 30), -30)))

# ---------------------------------------------------------------------
# Inicializa el modelo
#   nombres_vis : nombre de cada unidad visible (SKU o contexto)
#   n_ocultas   : cantidad de unidades ocultas (factores latentes)
#   X           : matriz binaria de entrenamiento (para iniciar sesgos)
# ---------------------------------------------------------------------
rbm_iniciar <- function(nombres_vis, n_ocultas = 8, X = NULL, semilla = 2026) {
  set.seed(semilla)
  nv <- length(nombres_vis)
  W  <- matrix(rnorm(nv * n_ocultas, 0, 0.01), nv, n_ocultas,
               dimnames = list(nombres_vis, paste0("h", seq_len(n_ocultas))))
  b  <- setNames(rep(0, nv), nombres_vis)            # sesgo visible
  if (!is.null(X)) {
    p <- pmin(pmax(colMeans(X), 0.01), 0.99)
    b <- setNames(log(p / (1 - p)), nombres_vis)
  }
  c  <- setNames(rep(0, n_ocultas), colnames(W))     # sesgo oculto
  list(W = W, b = b, c = c,
       dW = W * 0, db = b * 0, dc = c * 0,           # velocidades (momentum)
       curva = numeric(0))
}

# ---------------------------------------------------------------------
# Entrenamiento por CD-k
# ---------------------------------------------------------------------
rbm_entrenar <- function(m, X, epocas = 300, tasa = 0.05, lote = 16,
                         momentum = c(0.5, 0.9), decaimiento = 2e-4, k = 1,
                         semilla = 2026, verbose = FALSE) {
  set.seed(semilla)
  faltan <- setdiff(rownames(m$W), colnames(X))
  if (length(faltan)) X <- cbind(X, matrix(0, nrow(X), length(faltan), dimnames = list(NULL, faltan)))
  X <- X[, rownames(m$W), drop = FALSE]
  n <- nrow(X)
  for (ep in seq_len(epocas)) {
    mom <- if (ep <= 5) momentum[1] else momentum[2]
    orden <- sample(n)
    err <- 0
    for (ini in seq(1, n, by = lote)) {
      idx <- orden[ini:min(ini + lote - 1, n)]
      v0  <- X[idx, , drop = FALSE]
      ph0 <- sigmoide(sweep(v0 %*% m$W, 2, m$c, "+"))
      h   <- (ph0 > matrix(runif(length(ph0)), nrow(ph0))) * 1
      for (paso in seq_len(k)) {
        pv  <- sigmoide(sweep(h %*% t(m$W), 2, m$b, "+"))
        phk <- sigmoide(sweep(pv %*% m$W, 2, m$c, "+"))
        if (paso < k) h <- (phk > matrix(runif(length(phk)), nrow(phk))) * 1
      }
      nb <- nrow(v0)
      gW <- (t(v0) %*% ph0 - t(pv) %*% phk) / nb - decaimiento * m$W
      gb <- colMeans(v0 - pv)
      gc <- colMeans(ph0 - phk)
      m$dW <- mom * m$dW + tasa * gW
      m$db <- mom * m$db + tasa * gb
      m$dc <- mom * m$dc + tasa * gc
      m$W <- m$W + m$dW; m$b <- m$b + m$db; m$c <- m$c + m$dc
      err <- err + sum((v0 - pv)^2)
    }
    m$curva <- c(m$curva, err / n)
    if (verbose && ep %% 50 == 0) message(sprintf("época %d  error reconstrucción %.4f", ep, err / n))
  }
  m
}

# ---------------------------------------------------------------------
# Reconstrucción determinística (campo medio): p(v | h(v))
# ---------------------------------------------------------------------
rbm_reconstruir <- function(m, V) {
  if (is.null(dim(V))) V <- matrix(V, nrow = 1, dimnames = list(NULL, names(V)))
  V  <- V[, rownames(m$W), drop = FALSE]
  ph <- sigmoide(sweep(V %*% m$W, 2, m$c, "+"))
  pv <- sigmoide(sweep(ph %*% t(m$W), 2, m$b, "+"))
  colnames(pv) <- rownames(m$W)
  pv
}

# Energía libre (menor = más típico para el modelo)
rbm_energia_libre <- function(m, V) {
  V <- V[, rownames(m$W), drop = FALSE]
  -as.vector(V %*% m$b) - rowSums(log1p(exp(sweep(V %*% m$W, 2, m$c, "+"))))
}

# ---------------------------------------------------------------------
# Expande el modelo con unidades visibles nuevas (productos nuevos,
# segmentos nuevos) conservando lo aprendido -> "arranque en caliente"
# ---------------------------------------------------------------------
rbm_expandir <- function(m, nombres_nuevos, X = NULL) {
  nuevos <- setdiff(nombres_nuevos, rownames(m$W))
  if (!length(nuevos)) return(m)
  set.seed(99 + length(m$b))
  h  <- ncol(m$W)
  Wn <- matrix(rnorm(length(nuevos) * h, 0, 0.01), length(nuevos), h,
               dimnames = list(nuevos, colnames(m$W)))
  bn <- setNames(rep(-3, length(nuevos)), nuevos)
  if (!is.null(X)) {
    p <- pmin(pmax(colMeans(X[, nuevos, drop = FALSE]), 0.01), 0.99)
    bn <- setNames(log(p / (1 - p)), nuevos)
  }
  m$W  <- rbind(m$W, Wn);      m$dW <- rbind(m$dW, Wn * 0)
  m$b  <- c(m$b, bn);          m$db <- c(m$db, bn * 0)
  m
}
