# snowflake_jwt.R
# Snowflake SQL API helper using RSA/JWT authentication
# Uses only openssl + httr2 - no jose dependency
library(openssl)
library(httr2)

.get_private_key <- function() {
  pwd <- Sys.getenv("SNOWFLAKE_KEY_PWD")
  if (nchar(pwd) == 0) stop("SNOWFLAKE_KEY_PWD environment variable is not set.")
  b64 <- Sys.getenv("SNOWFLAKE_KEY_B64")
  if (nchar(b64) > 0) {
    key_bytes <- openssl::base64_decode(b64)
    tmp <- tempfile(fileext = ".p8")
    writeBin(key_bytes, tmp)
    on.exit(unlink(tmp))
    return(openssl::read_key(tmp, password = pwd))
  }
  path <- Sys.getenv("SNOWFLAKE_KEY_PATH")
  if (nchar(path) == 0) stop("Neither SNOWFLAKE_KEY_B64 nor SNOWFLAKE_KEY_PATH is set.")
  if (!file.exists(path)) stop("Key file not found: ", path)
  openssl::read_key(path, password = pwd)
}

.b64url_encode <- function(x) {
  b64 <- openssl::base64_encode(x)
  b64 <- gsub("\\+", "-", b64)
  b64 <- gsub("/",    "_", b64)
  b64 <- gsub("=+$",  "",  b64)
  b64 <- gsub("\n",  "",  b64)
  b64
}

.pubkey_fingerprint_sha256 <- function(pubkey) {
  der  <- openssl::write_der(pubkey)
  hash <- openssl::sha256(der)
  # Snowflake expects standard base64 encoding of the SHA256 hash
  openssl::base64_encode(hash)
}

.make_snowflake_jwt <- function(account, user) {
  key    <- .get_private_key()
  pub_fp <- .pubkey_fingerprint_sha256(key$pubkey)

  account_up <- toupper(account)
  user_up    <- toupper(user)

  iss <- paste0(account_up, ".", user_up, ".SHA256:", pub_fp)
  sub <- paste0(account_up, ".", user_up)
  now <- as.integer(Sys.time())

  header  <- .b64url_encode(charToRaw(jsonlite::toJSON(
    list(alg = "RS256", typ = "JWT"), auto_unbox = TRUE
  )))
  payload <- .b64url_encode(charToRaw(jsonlite::toJSON(
    list(iss = iss, sub = sub, iat = now, exp = now + 3600L),
    auto_unbox = TRUE
  )))

  signing_input <- paste0(header, ".", payload)

  sig <- openssl::rsa_sign(
    openssl::sha256(charToRaw(signing_input)),
    key = key
  )

  paste0(signing_input, ".", .b64url_encode(sig))
}

.parse_snowflake_response <- function(resp_json) {
  col_meta  <- resp_json$resultSetMetaData$rowType
  col_names <- sapply(col_meta, `[[`, "name")
  col_types <- sapply(col_meta, `[[`, "type")
  rows <- resp_json$data
  if (length(rows) == 0) {
    return(as.data.frame(
      setNames(replicate(length(col_names), character(0), simplify = FALSE),
               col_names)
    ))
  }
  df <- as.data.frame(
    do.call(rbind, lapply(rows, function(r) {
      sapply(r, function(x) if (is.null(x)) NA_character_ else as.character(x))
    })),
    stringsAsFactors = FALSE
  )
  names(df) <- col_names
  for (i in seq_along(col_names)) {
    col  <- col_names[i]
    type <- tolower(col_types[i])
    if (grepl("^(real|float|double|fixed|number)", type)) {
      df[[col]] <- suppressWarnings(as.numeric(df[[col]]))
    } else if (grepl("^timestamp", type) || grepl("^date", type)) {
      df[[col]] <- as.POSIXct(df[[col]], tz = "UTC")
    }
  }
  df
}

snowflake_query <- function(
    sql,
    account   = "LWSDAPW-HR81165",
    user      = "POWERBISVC",
    warehouse = "PROD_WH",
    database  = "ROCKIT_DATA_PROD",
    schema    = "COMPAC"
) {
  token <- .make_snowflake_jwt(account, user)
  url   <- paste0("https://", account, ".snowflakecomputing.com/api/v2/statements")
  resp <- httr2::request(url) |>
    httr2::req_headers(
      Authorization = paste("Bearer", token),
      `X-Snowflake-Authorization-Token-Type` = "KEYPAIR_JWT",
      `Content-Type` = "application/json",
      `Accept`       = "application/json",
      `User-Agent`   = "RShinyApp/1.0"
    ) |>
    httr2::req_body_json(list(
      statement  = sql,
      warehouse  = warehouse,
      database   = database,
      schema     = schema,
      parameters = list(
        TIMESTAMP_OUTPUT_FORMAT = "YYYY-MM-DD HH24:MI:SS.FF3",
        DATE_OUTPUT_FORMAT      = "YYYY-MM-DD"
      )
    )) |>
    httr2::req_error(is_error = function(r) FALSE) |>
    httr2::req_perform()
  status <- httr2::resp_status(resp)
  body   <- httr2::resp_body_json(resp)
  if (status != 200) {
    msg <- if (!is.null(body$message)) body$message else paste("HTTP", status)
    stop("Snowflake API error: ", msg)
  }
  .parse_snowflake_response(body)
}
