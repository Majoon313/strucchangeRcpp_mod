utils::globalVariables(c("i", "%dopar%"))

breakpoints <- function(obj, ...)
{
  UseMethod("breakpoints")
}

breakpoints.Fstats <- function(obj, ...)
{
  RVAL <- list(breakpoints = obj$breakpoint,
               RSS = obj$RSS,
               nobs = obj$nobs,
               nreg = obj$nreg,
               call = match.call(),
               datatsp = obj$datatsp)
  class(RVAL) <- "breakpoints"
  return(RVAL)
}

breakpoints.formula <- function(formula, h = 0.15, breaks = c("BIC", "LWZ", "RSS", "all"),
                                data = list(), hpc = c("none", "foreach"), ...)
{
  mf <- model.frame(formula, data = data)
  y <- model.response(mf)
  modelterms <- terms(formula, data = data)
  X <- model.matrix(modelterms, data = data)
  
  RVAL <- breakpoints.matrix(X, y, h = h, breaks = breaks, hpc = hpc, ...)
  
  n <- nrow(X)
  
  # Not sure if this is any different from what the object returned already, but just in case...
  if(is.ts(data)) {
    if(NROW(data) == n) datatsp <- tsp(data)
    else datatsp <- c(1/n, 1, n)      
  } else {
    env <- environment(formula)
    if(missing(data)) data <- env
    orig.y <- eval(attr(terms(formula), "variables")[[2]], data, env)
    if(is.ts(orig.y) & (NROW(orig.y) == n)) datatsp <- tsp(orig.y)
    else datatsp <- c(1/n, 1, n)
  }
  
  RVAL$datatsp <- datatsp
  return(RVAL)
}


breakpoints.matrix <- function(obj, y, h = 0.15, breaks = c("BIC", "LWZ", "RSS", "all"), hpc = c("none", "foreach"), ...)
{
  X <- obj
  n <- nrow(X)
  k <- ncol(X)
  breakstat <- NULL
  intercept_only <- isTRUE(all.equal(as.vector(X), rep(1L, n)))
  if(is.null(h)) h <- k + 1
  if(h < 1) h <- floor(n*h)
  if(h <= k)
    stop("minimum segment size must be greater than the number of regressors")
  if(h > floor(n/2))
    stop("minimum segment size must be smaller than half the number of observations")
  if (!is.numeric(breaks))
  {
    breakstat <- match.arg(breaks)
    breaks <- ceiling(n/h) - 2
  } else {
    if (length(breaks) > 1)
      stop("Argument 'breaks' takes a single number or method for optimal break estimation")
    if (breaks %% 1 != 0)
      stop("Please enter an integer number of breaks")
    if(breaks < 1) {
      breaks <- 1
      warning("number of breaks must be at least 1")
    }
      
    if(breaks > ceiling(n/h) - 2) {
      breaks0 <- breaks
      breaks <- ceiling(n/h) - 2
      warning(sprintf("requested number of breaks = %i too large, changed to %i", breaks0, breaks))
    }
  }

  hpc <- match.arg(hpc)
  if(hpc == "foreach") {
    if(requireNamespace("foreach")) {
      `%dopar%` <- foreach::`%dopar%`
    } else {
      warning("High perfomance computing (hpc) support with 'foreach' package is not available, foreach is not installed.")    
      hpc <- "none"
    }
  }

  ## compute ith row of the RSS diagonal matrix, i.e,
  ## the recursive residuals for segments starting at i = 1:(n-h+1)
  
  
  if (getOption("strucchange.use_armadillo", FALSE)) {
    res = .sc_cpp_construct_rss_table(y,X,n,h,breaks,intercept_only,sqrt(.Machine$double.eps)/ncol(X),getOption("strucchange.armadillo_rcond_min",sqrt(.Machine$double.eps)))
    RSS.table = res$RSS.table
    dimnames(RSS.table) = list(as.character(h:(n-h)), 
                               as.vector(rbind(paste("break", 1:breaks, sep = ""),paste("RSS", 1:breaks, sep = ""))))
    RSS.triang = res$RSS.triang
    RSS <- function(i, j) .sc_cpp_rss(RSS.triang, i, j)
    extend.RSS.table <- function(RSS.table, breaks) {
      if (2*breaks > ncol(RSS.table)) {
        RSS.table = .sc_cpp_extend_rss_table(rss_table = RSS.table, rss_triang = RSS.triang, n = n, h=h, breaks = breaks)
        dimnames(RSS.table) = list(as.character(h:(n-h)), as.vector(rbind(paste("break", 1:breaks, sep = ""),paste("RSS", 1:breaks, sep = ""))))
      }
      RSS.table
    }
  }
  else {

    RSSi <- function(i)
    {
      ssr <- if(intercept_only) {
        (y[i:n] - cumsum(y[i:n])/(1L:(n-i+1L)))[-1L] * sqrt(1L + 1L/(1L:(n-i)))
      } else {
      recresid(X[i:n,,drop = FALSE],y[i:n], ...)
      }
      c(rep(NA, k), cumsum(ssr^2))
    }
    
    ## employ HPC support if available/selected
    RSS.triang <- if(hpc == "none") sapply(1:(n-h+1), RSSi) else foreach::foreach(i = 1:(n-h+1)) %dopar% RSSi(i)
    
    ## function to extract the RSS(i,j) from RSS.triang
    RSS <- function(i,j) RSS.triang[[i]][j - i + 1]
    
    ## compute optimal previous partner if observation i is the mth break
    ## store results together with RSSs in RSS.table
    
    ## breaks = 1
    
    index <- h:(n-h)
    break.RSS <- sapply(index, function(i) RSS(1,i))
    
    RSS.table <- cbind(index, break.RSS)
    rownames(RSS.table) <- as.character(index)
    
    ## breaks >= 2
    
    extend.RSS.table <- function(RSS.table, breaks)
    {
      if((breaks*2) > ncol(RSS.table)) {
        for(m in (ncol(RSS.table)/2 + 1):breaks)
        {
          my.index <- (m*h):(n-h)
          my.RSS.table <- RSS.table[,c((m-1)*2 - 1, (m-1)*2)]
          my.RSS.table <- cbind(my.RSS.table, NA, NA)
          for(i in my.index)
          {
            pot.index <- ((m-1)*h):(i - h)
            break.RSS <- sapply(pot.index, function(j) my.RSS.table[as.character(j), 2] + RSS(j+1,i))
            opt <- which.min(break.RSS)
            my.RSS.table[as.character(i), 3:4] <- c(pot.index[opt], break.RSS[opt])
          }
          RSS.table <- cbind(RSS.table, my.RSS.table[,3:4])
        }
        colnames(RSS.table) <- as.vector(rbind(paste("break", 1:breaks, sep = ""),
                                               paste("RSS", 1:breaks, sep = "")))
      }
      return(RSS.table)
    }
    
    RSS.table <- extend.RSS.table(RSS.table, breaks)
  }
  
  ## extract optimal breaks

  extract.breaks <- function(RSS.table, breaks)
  {
    if((breaks*2) > ncol(RSS.table)) stop("compute RSS.table with enough breaks before")
    index <- RSS.table[, 1, drop = TRUE]
    break.RSS <- sapply(index, function(i) RSS.table[as.character(i),breaks*2] + RSS(i + 1, n))
    opt <- index[which.min(break.RSS)]
    if(breaks > 1) {
      for(i in ((breaks:2)*2 - 1))
        opt <- c(RSS.table[as.character(opt[1]),i], opt)
    }
    names(opt) <- NULL
    return(opt)
  }

  opt <- extract.breaks(RSS.table, breaks)
  
  if(is.ts(y) && NROW(y) == n)
  {
    datatsp <- tsp(y)
  } else {
    datatsp <- c(1/n, 1, n)
  }

  RVAL <- list(breakpoints = opt,
               RSS.table = RSS.table,
               RSS.triang = RSS.triang,
               RSS = RSS,
               extract.breaks = extract.breaks,
               extend.RSS.table = extend.RSS.table,
               nobs = n,
               nreg = k, y = y, X = X,
               call = match.call(),
               datatsp = datatsp)
  class(RVAL) <- c("breakpointsfull", "breakpoints")
  # If we are asked to find the optimal number of breakpoints according to a statistic, show the optimal one
  if (!is.null(breakstat))
    RVAL$breakpoints <- breakpoints(RVAL, breaks=breakstat)$breakpoints
  return(RVAL)
}



breakpoints.breakpointsfull <- function(obj, breaks = c("BIC", "LWZ", "RSS", "all"), ...)
{
  if (is.numeric(breaks))
  {
    if (length(breaks) > 1)
      stop("This function is for extracting a single break")
    if (breaks %% 1 != 0)
      stop("Please enter an integer number of breaks")
  } else if (is.null(breaks)) {
    breaks <- length(obj$breakpoints)
  } else
  {
    breakstat <- match.arg(breaks)
    sbp <- summary(obj)
    # Select optimal number of breaks by minimising a given statistic
    # Note: we might want to handle cases where the difference is < 2
    if (breakstat == "all")
      breaks <- ncol(sbp$breakpoints)
    else
      breaks <- which.min(sbp$RSS[breakstat,]) - 1
  }
  if(breaks < 1)
  {
    breakpoints <- NA
    RSS <- obj$RSS(1, obj$nobs)
  } else {
    RSS.tab <- obj$extend.RSS.table(obj$RSS.table, breaks)
    breakpoints <- obj$extract.breaks(RSS.tab, breaks)
    bp <- c(0, breakpoints, obj$nobs)
    RSS <- sum(apply(cbind(bp[-length(bp)]+1,bp[-1]), 1,
                     function(x) obj$RSS(x[1], x[2])))
  }
  fvals = fitted(obj, breaks=breaks, bp=breakpoints)
  mss = sum((fvals - mean(fvals))^2)
  r.squared = mss/(mss + RSS)
  RVAL <- list(breakpoints = breakpoints,
               RSS = RSS,
               nobs = obj$nobs,
               nreg = obj$nreg,
               call = match.call(),
               datatsp = obj$datatsp,
               r.squared = r.squared,
               MSS = mss)
  class(RVAL) <- "breakpoints"
  return(RVAL)
}


print.breakpoints <- function(x, format.times = NULL, ...)
{
  if(is.null(format.times)) format.times <- ((x$datatsp[3] > 1) & (x$datatsp[3] < x$nobs))
  if(any(is.na(x$breakpoints))) lbp <- 0
    else lbp <- length(x$breakpoints)
  cat(paste("\n\t Optimal ", lbp + 1, "-segment partition: \n\n", sep = ""))
  cat("Call:\n")
  print(x$call)
  cat("\nBreakpoints at observation number:\n")
  cat(x$breakpoints,"\n")
  cat("\nCorresponding to breakdates:\n")
  cat(breakdates(x, format.times = format.times),"\n")
}

breakdates <- function(obj, format.times = FALSE, ...)
{
  UseMethod("breakdates")
}

breakdates.breakpoints <- function(obj, format.times = FALSE, breaks = NULL, ...)
{
  if(inherits(obj, "breakpointsfull") && !is.null(breaks)) obj <- breakpoints(obj, breaks = breaks)
  if(is.null(format.times)) format.times <- ((obj$datatsp[3] > 1) & (obj$datatsp[3] < obj$nobs))

  format.time <- function(timevec, freq)
  {  
    first <- floor(timevec + .001)
    second <- floor(freq * (timevec - first) + 1 + .5 + .001)
    RVAL <- cbind(first, second)
    dummy <- function(x) paste(x[1], "(", x[2], ")", sep = "")
    RVAL <- apply(RVAL, 1, dummy)
    return(RVAL)
  }

  if(is.na(obj$breakpoints)[1])
    breakdates <- NA
  else {
    breakdates <- (obj$breakpoints - 1)/obj$datatsp[3] + obj$datatsp[1]
    if(format.times) breakdates <- format.time(breakdates, obj$datatsp[3])
  }

  return(breakdates)
}

breakfactor <- function(obj, breaks = NULL, labels = NULL, ...)
{
  if("breakpointsfull" %in% class(obj)) obj <- breakpoints(obj, breaks = breaks)
  breaks <- obj$breakpoints
  if(all(is.na(breaks))) return(factor(rep("segment1", obj$nobs)))
  nbreaks <- length(breaks)
  fac <- rep(1:(nbreaks + 1), c(breaks[1], diff(c(breaks, obj$nobs))))
  if(is.null(labels)) labels <- paste("segment", 1:(nbreaks+1), sep = "")
  fac <- factor(fac, labels = labels, ...)
  return(fac)
}

lines.breakpoints <- function(x, breaks = NULL, lty = 2, ...)
{
  if("breakpointsfull" %in% class(x)) x <- breakpoints(x, breaks = breaks)
  abline(v = breakdates(x), lty = lty, ...)
}

summary.breakpoints <- function(object, ...)
{
  print(object)
  cat(paste("\nRSS:", format(object$RSS),"MSS:", format(object$MSS), "\n"))
  cat(paste("Multiple R-squared:", format(object$r.squared),"\n"))
}

summary.breakpointsfull <- function(object, breaks = NULL,
  sort = NULL, format.times = NULL, ...)
{
  if(is.null(format.times)) format.times <- ((object$datatsp[3] > 1) & (object$datatsp[3] < object$nobs))
  if(is.null(breaks)) breaks <- ncol(object$RSS.table)/2
  n <- object$nobs
  RSS <- c(object$RSS(1, n), rep(NA, breaks))
  R.sq <- c(breakpoints(object, breaks = 0)$r.squared, rep(NA, breaks))
  BIC <- c(n * (log(RSS[1]) + 1 - log(n) + log(2*pi)) + log(n) * (object$nreg + 1),
           rep(NA, breaks))
  names(RSS) <- as.character(0:breaks)
  bp <- breakpoints(object, breaks = breaks)
  bd <- breakdates(bp, format.times = format.times, breaks=breaks)
  RSS[breaks + 1] <- bp$RSS
  R.sq[breaks + 1] <- bp$r.squared
  BIC[breaks + 1] <- AIC(bp, k = log(n))
  bp <- bp$breakpoints
  if(breaks > 1) {
  for(m in (breaks-1):1)
  {
    bp <- rbind(NA, bp)
    bd <- rbind(NA, bd)
    bpm <- breakpoints(object, breaks = m)
    if(is.null(sort) || identical(sort, TRUE)) {
      pos <- apply(outer(bpm$breakpoints, bp[nrow(bp),],
                   FUN = function(x,y) abs(x - y)), 1, which.min)
      if(length(pos) > length(unique(pos))) {
        if(!is.null(sort)) warning("sorting not possible", call. = FALSE)
	sort <- FALSE
      } else {
        sort <- TRUE
      }
    }
    if(!sort) pos <- 1:m
    bp[1,pos] <- bpm$breakpoints
    bd[1,pos] <- breakdates(bpm, format.times = format.times)
    RSS[m+1] <- bpm$RSS
    R.sq[m+1] <- bpm$r.squared
    BIC[m+1] <- AIC(bpm, k = log(n))
  }} else {
    bp <- as.matrix(bp)
    bd <- as.matrix(bd)
  }
  rownames(bp) <- as.character(1:breaks)
  colnames(bp) <- rep("", breaks)
  rownames(bd) <- as.character(1:breaks)
  colnames(bd) <- rep("", breaks)
  LWZ = LWZ.breakpointsfull(object)
  RSS <- rbind(RSS, BIC, LWZ, R.sq)
  rownames(RSS) <- c("RSS", "BIC", "LWZ", "R.sq")
  RVAL <- list(breakpoints = bp,
               breakdates = bd,
	       RSS = RSS,
	       call = object$call)
  class(RVAL) <- "summary.breakpointsfull"
  return(RVAL)
}

print.summary.breakpointsfull <- function(x, digits = max(2, getOption("digits") - 3), ...)
{
  bp <- x$breakpoints
  breaks <- ncol(bp)
  bd <- x$breakdates
  RSS <- x$RSS
  bp[is.na(bp)] <- ""
  bd[is.na(bd)] <- ""
  rownames(bp) <- paste("m = ", rownames(bp), "  ", sep = "")
  rownames(bd) <- paste("m = ", rownames(bd), "  ", sep = "")
  RSS <- rbind(0:(ncol(RSS) - 1), format(RSS, digits = digits))
  rownames(RSS) <- c("m","RSS", "BIC", "LWZ", "R.sq")
  colnames(RSS) <- rep("", breaks + 1)

  cat("\n\t Optimal (m+1)-segment partition: \n\n")
  cat("Call:\n")
  print(x$call)
  cat("\nBreakpoints at observation number:\n")
  print(bp, quote = FALSE)
  cat("\nCorresponding to breakdates:\n")
  print(bd, quote = FALSE)
  cat("\nFit:\n")
  print(RSS, quote = FALSE)
}

plot.breakpointsfull <- function(x, breaks = NULL, ...)
{
  rval <- summary(x, breaks = breaks)
  plot(rval, ...)
  invisible(rval)
}

plot.summary.breakpointsfull <- function(x, type = "b", col = c(1,4,5), legend = TRUE,
  xlab = "Number of breakpoints", ylab = "", main = "BIC, LWZ and Residual Sum of Squares", ...)
{
  breaks <- as.numeric(colnames(x$RSS))
  RSS <- x$RSS["RSS",]
  BIC <- x$RSS["BIC",]
  LWZ <- x$RSS["LWZ",]
  plot(breaks, BIC, ylab = "", ylim=c(min(c(BIC, LWZ)), max(c(BIC, LWZ))), xlab = xlab, main = main, type = type, col = col[1], ...)
  points(breaks, LWZ, col=col[3], type=type)
  onew <- getOption("new")
  par(new = TRUE)
  plot(breaks, RSS, type = type, axes = FALSE, col = col[2], xlab = "", ylab = "")
  if(legend) legend("topright", c("BIC", "RSS", "LWZ"), lty = rep(1, 2), col = col, bty = "n")
  axis(4)
  par(new = onew)
  invisible(x)
}



logLik.breakpoints <- function(object, ...)
{
  n <- object$nobs
  df <- (object$nreg + 1) * (length(object$breakpoints[!is.na(object$breakpoints)]) + 1)
  logL <- -0.5 * n * (log(object$RSS) + 1 - log(n) + log(2 * pi))
  attr(logL, "df") <- df
  class(logL) <- "logLik"
  return(logL)
}

logLik.breakpointsfull <- function(object, breaks = NULL, ...)
{
  bp <- breakpoints(object, breaks = breaks)
  logL <- logLik(bp)
  return(logL)
}

AIC.breakpointsfull <- function(object, breaks = NULL, ..., k = 2)
{
  if(is.null(breaks)) breaks <- 0:(ncol(object$RSS.table)/2)
  RVAL <- NULL
  for(m in breaks)
    RVAL <- c(RVAL, AIC(breakpoints(object, breaks = m), k = k))
  names(RVAL) <- breaks
  return(RVAL)
}

LWZ <- function(object, ...)
{
    UseMethod("LWZ")
}

LWZ.breakpointsfull <- function(object, ...)
{
    return(AIC.breakpointsfull(object, ..., k=0.299 * log(object$nobs)^2.1))
}

LWZ.breakpoints <- function(object, ...)
{
    return(AIC(object, k = 0.299 * log(object$nobs)^2.1))
}

pargmaxV <- function(x, xi = 1, phi1 = 1, phi2 = 1)
{
  phi <- xi * (phi2/phi1)^2

  G1 <- function(x, xi = 1, phi = 1)
  {
    x <- abs(x)
    frac <- xi/phi
    rval <- - exp(log(x)/2 - x/8 - log(2*pi)/2) -
              (phi/xi * (phi + 2*xi)/(phi+xi)) * exp((frac * (1 + frac) * x/2) + pnorm(-(0.5 + frac) * sqrt(x), log.p = TRUE)) +
	      exp(log(x/2 - 2 + ((phi + 2 * xi)^2)/((phi + xi)*xi)) + pnorm(-sqrt(x)/2, log.p = TRUE))
    rval
  }

  G2 <- function(x, xi = 1, phi = 1)
  {
    x <- abs(x)
    frac <- xi^2/phi
    rval <- 1 + sqrt(frac) * exp(log(x)/2 - (frac*x)/8  - log(2*pi)/2) +
            (xi/phi * (2*phi + xi)/(phi + xi)) * exp(((phi + xi) * x/2) + pnorm(-(phi + xi/2)/sqrt(phi) * sqrt(x), log.p = TRUE)) -
	    exp(log(((2*phi + xi)^2)/((phi+xi)*phi) - 2 + frac*x/2) + pnorm(-sqrt(frac) * sqrt(x)/2 , log.p = TRUE))
    rval
  }

  ifelse(x < 0, G1(x, xi = xi, phi = phi), G2(x, xi = xi, phi = phi))
}

confint.breakpointsfull <- function(object, parm = NULL, level = 0.95, breaks = NULL,
                                    het.reg = TRUE, het.err = TRUE, vcov. = NULL, sandwich = TRUE, ...)
{
  X <- object$X
  y <- object$y
  n <- object$nobs
  a2 <- (1 - level)/2
  if(!is.null(parm) & !is.null(breaks))
    warning("`parm' and `breaks' are both specified: `breaks' is used")
  else
    if(!is.null(parm)) breaks <- parm

  myfun <- function(x, level = 0.975, xi = 1, phi1 = 1, phi2 = 1)
    (pargmaxV(x, xi = xi, phi1 = phi1, phi2 = phi2) - level)

  myprod <- function(delta, mat) as.vector(crossprod(delta, mat) %*% delta)

  bp <- breakpoints(object, breaks = breaks)$breakpoints
  if(any(is.na(bp))) stop("cannot compute confidence interval when `breaks = 0'")
  
  nbp <- length(bp)
  upper <- rep(0, nbp)
  lower <- rep(0, nbp)
  bp <- c(0, bp, n)

  res <- residuals(object, breaks = breaks)
  sigma1 <- sigma2 <- sum(res^2)/n
  Q1 <- Q2 <- crossprod(X)/n

  if(is.null(vcov.))
    Omega1 <- Omega2 <- sigma1 * Q1
  else {
    y.nb <- rowSums(X) + res
    fm <- lm(y.nb ~ 0 + X)
    if(sandwich) {
      Omega1 <- Omega2 <- n * crossprod(Q1, vcov.(fm)) %*% Q1
    } else {
      Omega1 <- Omega2 <- vcov.(fm)
    }
  }

  xi <- 1

  X2 <- X[(bp[1]+1):bp[2],,drop = FALSE]
  y2 <- y[(bp[1]+1):bp[2]]
  fm2 <- lm(y2 ~ 0+ X2) 
  beta2 <- coef(fm2)
  if(het.reg) Q2 <- crossprod(X2)/nrow(X2)
  if(het.err) {
    sigma2 <- sum(residuals(fm2)^2)/nrow(X2)
    if(is.null(vcov.))
      Omega2 <- sigma2 * Q2
    else {
      if(sandwich) Omega2 <- nrow(X2) * crossprod(Q2, vcov.(fm2)) %*% Q2
        else Omega2 <- vcov.(fm2)
    }
  }

  for(i in 2:(nbp+1))
  {
    X1 <- X2
    y1 <- y2
    beta1 <- beta2
    sigma1 <- sigma2
    Q1 <- Q2
    Omega1 <- Omega2

    X2 <- X[(bp[i]+1):bp[i+1],,drop = FALSE]
    y2 <- y[(bp[i]+1):bp[i+1]]
    fm2 <- lm(y2 ~ 0 + X2) 
    beta2 <- coef(fm2)
    delta <- beta2 - beta1

    if(het.reg) Q2 <- crossprod(X2)/nrow(X2)
    if(het.err) {
      sigma2 <- sum(residuals(fm2)^2)/nrow(X2)
      if(is.null(vcov.))
        Omega2 <- sigma2 * Q2
      else {
        if(sandwich) Omega2 <- nrow(X2) * crossprod(Q2, vcov.(fm2)) %*% Q2
          else Omega2 <- vcov.(fm2)
      }
    }
        
    Oprod1 <- myprod(delta, Omega1)
    Oprod2 <- myprod(delta, Omega2)
    Qprod1 <- myprod(delta, Q1)
    Qprod2 <- myprod(delta, Q2)

    if(het.reg) xi <- Qprod2/Qprod1
    if(!is.null(vcov.)) phi1 <- sqrt(Oprod1/Qprod1)
      else phi1 <- sqrt(sigma1)
    if(!is.null(vcov.)) phi2 <- sqrt(Oprod2/Qprod2)
      else phi2 <- sqrt(sigma2)
 
    p0 <- pargmaxV(0, phi1 = phi1, phi2 = phi2, xi = xi)
    if(is.nan(p0) || p0 < a2 || p0 > (1-a2)) {
      warning(paste("Confidence interval", as.integer(i-1),
        "cannot be computed: P(argmax V <= 0) =", round(p0, digits = 4)))
      upper[i-1] <- NA
      lower[i-1] <- NA
    } else {
      ub <- lb <- 0
      while(pargmaxV(ub, phi1 = phi1, phi2 = phi2, xi = xi) < (1 - a2)) ub <- ub + 1000
      while(pargmaxV(lb, phi1 = phi1, phi2 = phi2, xi = xi) > a2) lb <- lb - 1000

      upper[i-1] <- uniroot(myfun, c(0, ub), level = (1-a2), xi = xi, phi1 = phi1, phi2 = phi2)$root
      lower[i-1] <- uniroot(myfun, c(lb, 0), level = a2, xi = xi, phi1 = phi1, phi2 = phi2)$root
    
      upper[i-1] <- upper[i-1] * phi1^2 / Qprod1
      lower[i-1] <- lower[i-1] * phi1^2 / Qprod1
    }
  }
  bp <- bp[-c(1, nbp+2)]
  bp <- cbind(bp - ceiling(upper), bp, bp - floor(lower))
  #V.BP# bp <- cbind(floor(bp - upper) - 1, bp, floor(bp - lower) + 1)
  a2 <- round(a2 * 100, digits = 1)
  colnames(bp) <- c(paste(a2, "%"), "breakpoints", paste(100 - a2, "%"))
  rownames(bp) <- 1:nbp
  RVAL <- list(confint = bp,
               nobs = object$nobs,
	       nreg = object$nreg,
	       call = match.call(),
               datatsp = object$datatsp)
  class(RVAL) <- "confint.breakpoints"
  return(RVAL)
}

breakdates.confint.breakpoints <- function(obj, format.times = FALSE, ...)
{
  bp <- list(breakpoints = NA, nobs = obj$nobs, datatsp = obj$datatsp)
  class(bp) <- "breakpoints"
  RVAL <- obj$confint
  for(i in 1:3) {
    bp$breakpoints <- obj$confint[,i]
    RVAL[,i] <- breakdates(bp, format.times = format.times, ...)
  }

  bp$breakpoints <- c(1, obj$nobs)
  startend <- breakdates(bp, format.times = NULL, ...)
  nbp <- nrow(obj$confint)
  if(any(obj$confint < 1) | any(obj$confint > obj$nobs))
    warning(paste("Confidence intervals outside data time interval\n\t from ",
            startend[1], " to ", startend[2], " (", obj$nobs, " observations)", sep = ""), call. = FALSE)
  if(any(obj$confint[-1,1] < obj$confint[-nbp,3]))
    warning("Overlapping confidence intervals", call. = FALSE)

  return(RVAL)
}

print.confint.breakpoints <- function(x, format.times = NULL, ...)
{
  if(is.null(format.times)) format.times <- ((x$datatsp[3] > 1) & (x$datatsp[3] < x$nobs))
  nbp <- nrow(x$confint)
  cat("\n\t Confidence intervals for breakpoints")
  cat(paste("\n\t of optimal ", nbp + 1, "-segment partition: \n\n", sep = ""))
  cat("Call:\n")
  print(x$call)
  cat("\nBreakpoints at observation number:\n")
  print(x$confint, quote = FALSE)
  cat("\nCorresponding to breakdates:\n")
  print(breakdates(x, format.times = format.times, ...), quote = FALSE)
}

lines.confint.breakpoints <- function(x, col = 2, angle = 90, length = 0.05,
  code = 3, at = NULL, breakpoints = TRUE, ...)
{
  nbp <- nrow(x$confint)
  x <- breakdates(x)
  if(breakpoints) abline(v = x[,2], lty = 2)
  if(is.null(at)) {
    at <- par("usr")[3:4]
    at <- diff(at)/1.08 * 0.02 + at[1]
  }
  if(length(at) < nbp) at <- rep(at, length.out = nbp)
  arrows(x[,1], at, x[,3], at, col = col, angle = angle, length = length, code = code, ...)
}

coef.breakpointsfull <- function(object, breaks = NULL, names = NULL, ...)
{
  X <- object$X
  y <- object$y
  n <- object$nobs
  bp <- obp <- breakpoints(object, breaks = breaks)$breakpoints
  if(any(is.na(bp))) {
    nbp <- 0
    bp <- c(0, n)
  } else {
    nbp <- length(bp)
    bp <- c(0, bp, n)
  }
  
  if(!is.null(names)) {
    if(length(names) == 1) names <- paste(names, 1:(nbp+1))
      else if(length(names) != (nbp+1)) names <- NULL
  }
  if(is.null(names)) {
    bd1 <- structure(list(breakpoints = bp[-(nbp+2)] + 1, nobs = n, datatsp = object$datatsp),
                    class = "breakpoints")
    bd2 <- structure(list(breakpoints = bp[-1], nobs = n, datatsp = object$datatsp),
                    class = "breakpoints")
    bd1 <- breakdates(bd1, format.times = NULL)
    bd2 <- breakdates(bd2, format.times = NULL)
    names <- paste(bd1, "-", bd2) 
  }
    
  rval <- NULL

  for(i in 1:(nbp+1))
  {
    X2 <- X[(bp[i]+1):bp[i+1],,drop = FALSE]
    y2 <- y[(bp[i]+1):bp[i+1]]
    rval <- rbind(rval, lm.fit(X2, y2)$coef)
  }
  
  rownames(rval) <- names
  return(rval)
}

fitted.breakpointsfull <- function(object, breaks = NULL, bp=NULL, ...)
{
  X <- object$X
  y <- object$y
  n <- object$nobs
  if (is.null(bp))
    bp <- obp <- breakpoints(object, breaks = breaks)$breakpoints
  else obp <- bp
  if(any(is.na(bp))) {
    nbp <- 0
    bp <- c(0, n)
  } else {
    nbp <- length(bp)
    bp <- c(0, bp, n)
  }
  rval <- NULL

  for(i in 1:(nbp+1))
  {
    X2 <- X[(bp[i]+1):bp[i+1],,drop = FALSE]
    y2 <- y[(bp[i]+1):bp[i+1]]
    rval <- c(rval, lm.fit(X2, y2)$fitted.values)
  }
  rval <- ts(as.vector(rval))
  tsp(rval) <- object$datatsp
  
  return(rval)
}

residuals.breakpointsfull <- function(object, breaks = NULL, ...)
{
  X <- object$X
  y <- object$y
  n <- object$nobs
  bp <- obp <- breakpoints(object, breaks = breaks)$breakpoints
  if(any(is.na(bp))) {
    nbp <- 0
    bp <- c(0, n)
  } else {
    nbp <- length(bp)
    bp <- c(0, bp, n)
  }
  rval <- NULL

  for(i in 1:(nbp+1))
  {
    X2 <- X[(bp[i]+1):bp[i+1],,drop = FALSE]
    y2 <- y[(bp[i]+1):bp[i+1]]
    rval <- c(rval, lm.fit(X2, y2)$residuals)
  }
  rval <- ts(as.vector(rval))
  tsp(rval) <- object$datatsp
    
  return(rval)
}

vcov.breakpointsfull <- function(object, breaks = NULL, names = NULL, het.reg = TRUE,
                                 het.err = TRUE, vcov. = NULL, sandwich = TRUE, ...)
{
  X <- object$X
  y <- object$y
  n <- object$nobs

  bp <- breakpoints(object, breaks = breaks)$breakpoints
  if(any(is.na(bp))) {
    nbp <- 0
    bp <- c(0, n)
  } else {
    nbp <- length(bp)
    bp <- c(0, bp, n)
  }

  if(!is.null(names)) {
    if(length(names) == 1) names <- paste(names, 1:(nbp+1))
      else if(length(names) != (nbp+1)) names <- NULL
  }
  if(is.null(names)) {
    bd1 <- structure(list(breakpoints = bp[-(nbp+2)] + 1, nobs = n, datatsp = object$datatsp),
                    class = "breakpoints")
    bd2 <- structure(list(breakpoints = bp[-1], nobs = n, datatsp = object$datatsp),
                    class = "breakpoints")
    bd1 <- breakdates(bd1, format.times = NULL)
    bd2 <- breakdates(bd2, format.times = NULL)
    names <- paste(bd1, "-", bd2) 
  }
    
  res <- residuals(object, breaks = breaks)
  sigma2 <- sum(res^2)/n
  Q2 <- crossprod(X)/n

  if(is.null(vcov.))
    Omega2 <- sigma2 * solve(Q2) / n
  else {
    y.nb <- rowSums(X) + res
    fm <- lm(y.nb ~ 0 + X)
    if(sandwich) {
      Omega2 <- vcov.(fm)
    } else {
      modelv <- summary(fm)$cov.unscaled
      Omega2 <- n * modelv %*% vcov.(fm) %*% modelv
    }
  }
  rownames(Omega2) <- colnames(Omega2) <- colnames(X)

  rval <- list()

  for(i in 1:(nbp+1))
  {
    X2 <- X[(bp[i]+1):bp[i+1],,drop = FALSE]
    y2 <- y[(bp[i]+1):bp[i+1]]
    fm2 <- lm(y2 ~ 0 + X2) 

    if(het.reg) Q2 <- crossprod(X2)/nrow(X2)
    if(het.err) {
      sigma2 <- sum(residuals(fm2)^2)/nrow(X2)
      if(is.null(vcov.))
        Omega2 <- sigma2 * solve(Q2) / nrow(X2)
      else {
        if(sandwich) {
          Omega2 <- vcov.(fm2)
        } else {
          modelv <- summary(fm2)$cov.unscaled
          Omega2 <- n * modelv %*% vcov.(fm2) %*% modelv
        }
      }
      rownames(Omega2) <- colnames(Omega2) <- colnames(X)
    }
    rval[[i]] <- Omega2
  }
    
  names(rval) <- names
  return(rval)
}

df.residual.breakpointsfull <- function(object, ...)
{
  rval <- table(breakfactor(object, ...)) - object$nreg
  names(rval) <- rownames(coef(object, ...))
  return(rval)
}

magnitude <- function(object, ...)
{
  UseMethod("magnitude")
}

# Returns a vector of magnitudes of change
magnitude.breakpointsfull <- function(object, interval = 0.1, breaks = NULL, component = "trend", ...)
{
    X <- object$X[,!colnames(object$X) %in% "(Intercept)", drop=FALSE] # Do not take intercept
    y <- object$y
    # Also filter out the intercept from the components, in case users are lazy and put in all model names()
    component <- component[!component %in% "(Intercept)"]
    if (interval <= 0 || interval > length(y))
        stop("Requested interval for magnitude computation out of valid range")
    if (interval < 1)
        interval <- floor(length(y)*interval) # Convert to number of samples #TODO: Add handling of time
    bp <- breakpoints(object, breaks=breaks)$breakpoints
    nrbp <- length(bp)
    if (nrbp < 2 && is.na(bp))
        stop("There are no breakpoints to calculate magnitudes for!")
    if (!any(colnames(object$X) %in% component))
        stop(paste("The specified component", component, "is missing"))
    co  <- coef(object, breaks=breaks)
    
    Mag <- matrix(NA, nrbp, 6)
    for (i in 1:nrbp) {
        interval_start <- max(bp[i]-interval, 1)
        interval_end   <- min(bp[i]+interval, nrow(X))
        
        # Fitted components over the interval range from the breakpoint
        fit_prev <- co[i,   "(Intercept)"]
        fit_next <- co[i+1, "(Intercept)"]
        for (comp in component) {
            fit_prev <- X[interval_start:interval_end,comp] * co[i,   comp] + fit_prev
            fit_next <- X[interval_start:interval_end,comp] * co[i+1, comp] + fit_next
        }
        
        # First fitted values before and after the break; for legacy reasons
        Mag[i, 1] <- co[i,   "(Intercept)"]
        Mag[i, 2] <- co[i+1, "(Intercept)"]
        for (comp in component) {
            Mag[i, 1] <- X[bp[i],  comp] * co[i,   comp] + Mag[i, 1]
            Mag[i, 2] <- X[bp[i]+1,comp] * co[i+1, comp] + Mag[i, 2]
        }
        Mag[i, 3] <- Mag[i, 2] - Mag[i, 1]
        Mag[i, 4] <- sqrt(mean((fit_next - fit_prev)^2))
        Mag[i, 5] <- mean(abs(fit_next - fit_prev))
        Mag[i, 6] <- mean(fit_next - fit_prev)
        
        colnames(Mag) = c("before", "after", "diff", "RMSD", "MAD", "MD")
        
    }
    index <- which.max(abs(Mag[, 3]))
    m.x <- rep(bp[index], 2)
    m.y <- c(Mag[index, 1], Mag[index, 2]) #Magnitude position
    Magnitude <- Mag[index, 3] # Magnitude of biggest change
    Time <- bp[index]
    
    Result <- list(Mag=Mag, m.x=m.x, m.y=m.y, Magnitude=Magnitude, Time=Time)
    class(Result) <- "magnitude"
    return(Result)
}
