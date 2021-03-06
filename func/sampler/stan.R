# TODO: Dynamically adjust step size
library(rstan)
library(parallel)

glrm_sampler_stan <- 
  function(Y, lambda, 
           family_name = c("gaussian", "poisson"), 
           prior_name = 
             c("gaussian", "sparse", "sparse_plus", 
               "dirichlet", "dirichlet_sparse", 
               "dirichlet_sparse_gam_full",
               "dirichlet_sparse_gam_sample"),
           init, config, rec, info, 
           stan_algorithm = c("hmc", "vi"))
  {
    family_name <- match.arg(family_name)
    prior_name <- match.arg(prior_name)
    stan_algorithm <- match.arg(stan_algorithm)
    
    # unpack family properties
    n <- info$n 
    p <- info$p
    k <- info$k
    true_theta <- info$true_par$theta
    
    family <- glrm_family(family_name)
    T_suff <- family$sufficient(Y)
    negloglik <- family$negloglik
    
    # unpack mcmc parameters
    record_freq <- config$record_freq
    time_max <- config$time_max
    
    iter_max <- config$sampler$iter_max
    step_size <- config$sampler$step_size
    frog_step <- config$sampler$frog_step  
    mmtm_freq <- config$sampler$mmtm_freq 
    rotn_freq <- config$sampler$rotn_freq  
    samp_seed <- config$sampler$samp_seed
    parm_updt <- config$sampler$parm_updt
    
    # initiate sampler
    rstan_options(auto_write = TRUE)
    options(mc.cores = parallel::detectCores())    
    stan_addr <- "./func/sampler/stan/"
    model_name <- family_name
    
    model_name <- 
      paste0(family_name, "_", prior_name)
    
    stan_data <- list(N = n, P = p, K = k, Y = Y,
                      lambda_u = lambda, 
                      lambda_v = lambda, 
                      v_p = 3, v_k = 2.5)
    
    
    if (grepl("dirichlet", prior_name)) {# TODO
      # profile <- 
      #   list(c(2, 5, 3, 16), 
      #        c(1, 3, 7, 13), 
      #        c(1, 6, 10, 16), 
      #        c(1, 4, 10, 14), 
      #        c(3, 4, 5, 14))
      # p_eps_val <- 1e-4
      # p_V <- # uniform prior
      #   matrix((1-(p_eps_val * (k-1)))/(p-k+1), nrow = k, ncol = p) 
      # for (j in 1:nrow(p_V)) 
      #   p_V[j, profile[[j]]] <- p_eps_val
      
      p_V <- matrix(1/p, nrow = k, ncol = p)
      stan_data$p_V <- p_V
      
      init$V <- 
        apply(p_V, 1, function(p) rdiric(1, p))
      init$U <- matrix(rexp(n*k), nrow = n, ncol = k)
    }
    
    if (grepl("gam", prior_name)) {
      # covariate with time effect
      stan_data$Q <- 1 + config$prior$ns_df
      
      time <- 1:nrow(Y)
      X <- cbind(1, ns(time, df = config$prior$ns_df))
      stan_data$X <- X
    }
    
    if (length(parm_updt) > 1){
      stan_file <- paste0(stan_addr, model_name, ".stan")
    } else if (parm_updt == "U"){
      stan_file <- paste0(stan_addr, model_name, "_U.stan")
      stan_data$V <- init$V
    } else if (parm_updt == "V") {
      stan_file <- paste0(stan_addr, model_name, "_V.stan")
      stan_data$U <- init$U
    }
    
    # determine initial value using vb adaptation
    cat("Identifying initial values..")
    # define object
    obj <- stan_model(stan_file, model_name) 
    init_func <- function() init
    
    # obtain adapted stepsize
    model_text_init <- 
      capture.output(
        model_init <- 
          vb(obj, data = stan_data, 
             init = init_func,
             seed = samp_seed,
             iter = 1,
             adapt_iter = 1000, 
             output_samples = 1)
      )
    
    # rec_init <- model_init@sim$samples[[1]]
    # init$U <- 
    #   rec_init[grep("^U\\.", names(rec_init))] %>% 
    #   abind(along = 0) %>% t %>% array(dim = c(n, k))
    # init$V <- 
    #   rec_init[grep("^V\\.", names(rec_init))] %>% 
    #   abind(along = 0) %>% t %>% array(dim = c(p, k))
    
    cat("Done\n")
    
    # execute sampler
    cat("Compiling..")
    if (stan_algorithm == "hmc"){
      cat("HMC in process..")
      #TODO: read initial values generated by VI
      
      
      time0 <- Sys.time()
      
      model_text <- 
        capture.output(
          model_out <- 
            stan(stan_file, model_name,
                 chains = 1, data = stan_data,
                 iter = iter_max, 
                 init = init_func,
                 seed = samp_seed, 
                 algorithm = "NUTS",
                 pars = NA, # want all parameters
                 #control = list(adapt_engaged = FALSE),
                 verbose = TRUE,
                 control = list(adapt_delta = 0.99, 
                                max_treedepth = 50)
            )
        )
      
      # grep time:
      time_info_id <-
        which(sapply(model_text,
                     function(s) grep("(Total)", s))>0)
      time_max <- gsub("[a-zA-Z\\(\\)]", "",
                       model_text[time_info_id]) %>% as.numeric()
      
      # result
      rec_list <- model_out@sim$samples[[1]]
      rec$hmc_param <-
        get_sampler_params(model_out, inc_warmup = FALSE)
      
      time_list <- 
        seq(0, time_max/60, 
            length.out = round(iter_max/record_freq))
    } else if (stan_algorithm == "vi"){
      cat("VI in process..\n")
      
      # define outcome container
      vi_iter_list <- 
        seq(1, iter_max, record_freq)
      n_param <- n*k + p*k + n*p + 2
      rec_list <- NULL
      
      # find step size 
      stepsize_info_id <- 
        which(sapply(model_text_init, 
                     function(s) grep("Success! Found best value", s))>0)
      eta_info <- 
        gsub("^.*\\[eta = |\\].*$", "", 
             model_text_init[stepsize_info_id]) %>% as.numeric()
      
      # formal sampling
      time_list <- 
        rep(NaN, length(vi_iter_list))
      pb <- 
        txtProgressBar(0, length(vi_iter_list), style = 3)
      
      for (i in 1:length(vi_iter_list)){
        setTxtProgressBar(pb, i)
        iter <- vi_iter_list[i]
        model_text <- 
          capture.output(
            model_out <- 
              vb(obj, data = stan_data, 
                 init = init_func,
                 seed = samp_seed,
                 iter = iter,
                 output_samples = 3,
                 adapt_engaged = FALSE, 
                 eta = eta_info)
          )
        
        # grep time:
        time_info_id <- 
          which(sapply(model_text, 
                       function(s) grep("Gradient evaluation", s))>0)
        time_info <- gsub("Gradient evaluation took | seconds", "", 
                          model_text[time_info_id]) %>% as.numeric()
        
        time_list[i] <- time_info
        
        # add to existing result
        if (is.null(rec_list)){
          # if not yet initiated, initiate rec_list to named list of variables
          rec_list <- model_out@sim$samples[[1]]
        } else {
          rec_list <- 
            Map(c, rec_list, model_out@sim$samples[[1]])
        }
      }
      time_list <- cumsum(time_list)
    }
    
    cat("\nDone\n")
    
    # return
    rec_name_pattern <- 
      ifelse(stan_algorithm == "hmc", "\\[.*", "\\..*")
    rec_dim_pattern1 <- 
      ifelse(stan_algorithm == "hmc", "^.*\\[|\\]", "^.?\\.")
    rec_dim_pattern2 <- 
      ifelse(stan_algorithm == "hmc", ",", "\\.")
    
    rec_name <- sapply(names(model_out@sim$samples[[1]]), 
                       function(x) 
                         gsub(rec_name_pattern, "", x))
    
    rec <- NULL
    rec$time <- time_list
    for (name in unique(rec_name)){
      idx <- which(rec_name == name)
      if (length(idx) > 1){
        dim_2_name <- 
          names(rec_list)[max(idx)] %>% 
          gsub(rec_dim_pattern1, "", .) %>% 
          strsplit(rec_dim_pattern2) %>% extract2(1)
        dim_2 <- dim_2_name[length(dim_2_name)] %>% as.numeric
        dim_1 <- length(idx)/dim_2
      } else {
        dim_1 = dim_2 = 1
      }
      
      rec[[name]] <- 
        rec_list[idx] %>% abind(along = 0) %>% t %>% 
        array(dim = c(iter_max, dim_1, dim_2))
    }
    
    record_idx <- seq(1, iter_max, record_freq)
    
    rec$U <- abind(init$U, rec$U[record_idx, , ], along = 1)
    rec$V <- abind(init$V, rec$V[record_idx, , ], along = 1)
    rec$Theta <- abind(init$U %*% t(init$V), 
                       rec$Theta[record_idx, , ], along = 1)
    rec$init <- init
    
    if (length(parm_updt) > 1){
      rec$obj <-
        sapply(1:round(iter_max/record_freq), 
               function(i){
                 negloglik(T_suff, rec$Theta[i, ,]) + 
                   (lambda/2) * (sum(rec$U[i, ,]^2) + sum(rec$V[i, ,]^2))
               }
        )  
    } else if (parm_updt == "U"){
      rec$obj <-
        sapply(1:round(iter_max/record_freq), 
               function(i){
                 negloglik(T_suff, rec$Theta[i, ,]) + 
                   (lambda/2) * (sum(init$V^2) + sum(rec$U[i, ,]^2))
               }
        )
    } else if (parm_updt == "V") {
      rec$obj <-
        sapply(1:round(iter_max/record_freq), 
               function(i){
                 negloglik(T_suff, rec$Theta[i, ,]) + 
                   (lambda/2) * (sum(init$U^2) + sum(rec$V[i, ,]^2))
               }
        )    
    }
    
    # return
    rec$model_out <- model_out
    rec
  }