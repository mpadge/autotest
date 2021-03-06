
# extracts the i-th list of complete parameters from the result of a parsed yaml
get_params <- function (res, i, this_fn) {
    p <- res$parameters [[i]]
    p_keys <- vapply (p, function (i) names (i), character (1))
    # vals as list to allow different types of data
    p_vals <- lapply (p, function (i) i [[1]])

    # remove any with NULL values
    #index <- which (vapply (p_vals, function (i) !is.null (i), logical (1)))
    #p_keys <- p_keys [index]
    #p_vals <- p_vals [index]

    . <- NULL # suppress no visible binding note # nolint
    pre <- res$preprocess [[i]]
    e <- new.env ()
    for (p in pre) {
        expr <- parse (text = gsub ("`", "", p))
        suppressMessages (
            tmp <- tryCatch (utils::capture.output (eval (expr, envir = e)),
                             error = function (e) NULL)
        )
    }

    params <- fill_param_vals (p_keys, p_vals, e, res$package)

    # Parse fn definition to get list of all parameters:
    if (!res$package %in% search ())
        suppressMessages (
            library (res$package, character.only = TRUE)
            )
    pkg_env <- as.environment (paste0 ("package:", res$package))
    pars <- formals (fun = this_fn, envir = pkg_env)
    nms <- names (pars)

    pars <- clean_final_pars_list (params, pars, nms)

    # Add all resultant params from fn definition yet not directly specified to
    # the return list.
    for (p in seq (pars)) {
        params [[length (params) + 1]] <- pars [[p]]
        names (params) [length (params)] <- names (pars) [p]
    }

    # finally, remove any params that are if conditionals, since evaluting these
    # requires parsing and evaluating all other parameters, and if conditions
    # can not be mutated anyway
    index <- which (vapply (params, function (i) !methods::is (i, "if"),
                            logical (1)))
    params <- params [index]

    return (params)
}

# Get the 'value' field from an Rd entry for a given package function:
get_Rd_value <- function (package, fn_name) { # nolint
    val <- NULL

    if (pkg_is_source (package)) {
        f <- file.path (package, "man", paste0 (fn_name, ".Rd"))
        suppressWarnings (
            rd <- tools::parse_Rd (f)
            )
    } else {
        if (basename (package) == package) {
            x <- tools::Rd_db (package = package)
        } else {
            # packages installed into local tempdir via covr:
            x <- tools::Rd_db (package = basename (package),
                               dir = package)
        }
        rd <- x [[paste0 (fn_name, ".Rd")]]
    }


    val <- get_Rd_metadata (rd, "value")
    if (length (val) == 0)
        return (NULL)

    val <- strsplit (val, "\\n") [[1]]
    index <- which (grepl ("^list\\(", val))
    val [index] <- vapply (val [index], function (i)
                           paste0 (unlist (eval (parse (text = i))),
                                   collapse = " "),
                           character (1))
    val <- gsub ("\\s+", " ", paste0 (val, collapse = " "))

    return (val)
}

get_Rd_param <- function (package, fn_name, param_name) { # nolint

    if (pkg_is_source (package)) {

        f <- file.path (package, "man", paste0 (fn_name, ".Rd"))
        suppressWarnings (
            rd <- tools::parse_Rd (f)
            )
    } else {

        if (basename (package) == package) {

            x <- tools::Rd_db (package = package)
        } else {

            # packages installed into local tempdir via covr:
            x <- tools::Rd_db (package = basename (package),
                               dir = package)
        }

        rd <- x [[paste0 (fn_name, ".Rd")]]
    }

    tags <- vapply (rd, function (i) attr (i, "Rd_tag"), character (1))
    if ("\\arguments" %in% tags)
        rd <- rd [[which (tags == "\\arguments")]]
    index <- vapply (rd, function (i) attr (i, "Rd_tag"), character (1))
    rd <- rd [which (index == "\\item")]

    params <- vapply (rd, function (i) as.character (i [[1]]), character (1))
    ret <- NA_character_
    if (param_name %in% params)
        ret <- as.character (rd [[which (params == param_name)]] [[2]] [[1]])
    return (ret)
}

get_param_descs_source <- function (package, fn) {
    f <- file.path (package, "man", paste0 (fn, ".Rd"))
    x <- readLines (f, warn = FALSE)

    # get the value descriptions
    x <- x [grep ("^\\\\arguments\\{", x):length (x)]
    x <- x [2:(match_curlies (x) - 1)]
    x <- x [x != ""]

    index <- grep ("^\\\\item\\{", x)
    index <- rep (seq (index),
                  times = c (diff (index), length (x) - max (index) + 1))
    xs <- split (x, f = as.factor (index))

    items <- vapply (xs, function (i) {
                         i <- gsub ("^\\\\item\\{|\\}$", "", i)
                         return (strsplit (i, "\\}") [[1]] [1]) },
                         character (1), USE.NAMES = FALSE)
    descs <- vapply (xs, function (i) {
                         i <- paste0 (gsub ("^\\\\item\\{|\\}$", "", i),
                                      collapse = " ")
                         return (substr (i, regexpr ("\\{", i) + 1, nchar (i)))
                         },
                         character (1), USE.NAMES = FALSE)

    names (descs) <- items

    return (descs)
}

fill_param_vals <- function (p_keys, p_vals, e, package) {

    params <- list ()

    for (p in seq_along (p_keys)) {

        this_val <- p_vals [[p]]
        if (is.null (this_val))
            next

        this_val <- get_non_formula_val (this_val,
                                         e,
                                         package,
                                         p_vals,
                                         p)
        # leave formulae as strings:
        if (methods::is (this_val, "formula"))
            this_val <- p_vals [[p]]

        params [[length (params) + 1]] <- this_val
        names (params) [length (params)] <- p_keys [p]
    }

    return (params)
}

# stats::var is a good example where param, `x`, is passed as a formula and
# evaluated here via !can_get but can_eval.
get_non_formula_val <- function (this_val, e, package, p_vals, p) {

    if (is.name (this_val)) {

        temp_val <- paste0 (this_val)

        can_get <- !is.null (tryCatch (get (temp_val),
                                       error = function (e) NULL))
        can_eval <- !is.null (tryCatch (eval (parse (text = this_val),
                                              envir = e),
                                        error = function (err) NULL))

        if (can_get) {
            this_val <- get (temp_val, envir = e)
        } else if (can_eval) {
            this_val <- eval (parse (text = this_val), envir = e)
        } else if (temp_val %in% ls (envir = e)) {
            this_val <- get (temp_val, envir = e)
        } else if (temp_val %in%
                   ls (paste0 ("package:", package))) {
            e <- as.environment (paste0 ("package:", package))
            this_val <- get (temp_val, envir = e)
        } else if (grepl ("::", temp_val)) {
            this_pkg <- strsplit (temp_val, "::") [[1]] [1]
            if (!this_pkg %in% search ())
                suppressMessages (
                                  library (this_pkg,
                                           character.only = TRUE)
                )
            this_val <- parse (text = temp_val) %>%
                eval (envir = as.environment (paste0 ("package:",
                                                      this_pkg)))
        }

    } else if (is.character (this_val)) {

        if (this_val %in% names (e)) {
            this_val <- parse (text = this_val) %>%
                eval (envir = e)
        } else if (grepl ("::", this_val)) {
            this_pkg <- strsplit (p_vals [[p]], "::") [[1]] [1]
            if (!this_pkg %in% search ())
                suppressMessages (
                                  library (this_pkg, character.only = TRUE)
                )
            this_val <- parse (text = this_val) %>%
                eval (envir = as.environment (paste0 ("package:",
                                                      this_pkg)))
        } else {
            tryeval <- tryCatch (eval (parse (text = this_val)),
                                 error = function (e) NULL)
            # Character values may also name functions, in which case these
            # should NOT be assigned to the values. An example is ?var which has
            # `method = "complete"`, where "complete" is also a function.
            if (!is.null (tryeval))
                if (!methods::is (tryeval, "function"))
                    this_val <- tryeval
        }
    }

    return (this_val)
}

clean_final_pars_list <- function (params, pars, nms) {

    # If fn includes ... AND any submitted params are not named, then remove the
    # ... from returned list
    if ("..." %in% nms & any (!names (params) %in% nms)) {
        pars <- pars [which (!nms == "...")]
        nms <- nms [which (!nms == "...")]
    }

    # parameters in formals with no default values are returned as empty
    # 'symbol' expressions - this converts these to "MISSING":
    pars <- lapply (pars, function (i) {
                if (typeof (i) == "symbol" & all (deparse (i) == ""))
                    return ("MISSING")
                else if (is.null (i))
                    return ("NULL")
                else
                    return (i)
            })
    pars <- pars [which (!nms %in% names (params))]
    nms <- nms [which (!nms %in% names (params))]
    # That can then be used to check that any with non-default values have been
    # provided:
    if (any (pars == "MISSING")) {
        no_defaults <- nms [which (pars == "MISSING")]
        no_defaults <- no_defaults [which (no_defaults %in% names (params))]
        if (length (no_defaults) > 0)
            stop ("function includes the following parameters which require ",
                  "non-default values:\n   [",
                  paste0 (no_defaults, collapse = ", "),
                  "]")
        # The rest must be in params, so the default "MISSING" entries can be
        # removed here:
        pars <- pars [which (pars != "MISSING")]
    }

    return (pars)
}
