# Rockit SKU Simulation App

A Shiny application for apple sizing and SKU simulation, connecting to Snowflake via RSA/JWT authentication using the Snowflake SQL API.

---

## Architecture

```
app.R
 └── source("global.R")          # runs at startup, loads Snowflake data
      └── source("snowflake_jwt.R")  # JWT auth + SQL API query helper
.Renviron                        # credentials (never commit this)
```

---

## File Overview

| File | Purpose |
|------|---------|
| `app.R` | Main Shiny app — UI and server logic |
| `global.R` | Runs once at startup, executes Snowflake query, creates `compac_stats` |
| `snowflake_jwt.R` | Self-contained helper: builds RSA/JWT token, calls Snowflake SQL API, returns data frame |
| `.Renviron` | Environment variables for credentials (excluded from git) |

---

## Authentication

The app authenticates to Snowflake using **RSA key-pair / JWT authentication** via the [Snowflake SQL API v2](https://docs.snowflake.com/en/developer-guide/sql-api/index). This avoids the need for ODBC drivers, which are not available on shinyapps.io.

The JWT is built manually using only the `openssl` and `httr2` R packages — no `jose` dependency — to avoid package masking conflicts on the deployment server.

### How it works

1. The private key is read from disk (local) or decoded from a base64 environment variable (shinyapps.io)
2. A SHA256 fingerprint of the public key is computed using `write_der()` + `sha256()` + `base64_encode()`
3. A JWT is constructed with `iss`, `sub`, `iat`, `exp` claims and signed with `rsa_sign()`
4. The JWT is sent as a Bearer token in the `Authorization` header to the Snowflake SQL API
5. The response JSON is parsed into a data frame

---

## Environment Variables

Three environment variables are required. Set these in `.Renviron` (project-level, not user-level).

| Variable | Description |
|----------|-------------|
| `SNOWFLAKE_KEY_PWD` | Passphrase for the encrypted private key file |
| `SNOWFLAKE_KEY_PATH` | Path to the `.p8` key file — **local only** |
| `SNOWFLAKE_KEY_B64` | Base64-encoded contents of the `.p8` key file — **shinyapps.io only** |

The helper automatically detects the environment: if `SNOWFLAKE_KEY_B64` is set it uses that; otherwise it falls back to `SNOWFLAKE_KEY_PATH`.

### Local `.Renviron` example

```
SNOWFLAKE_KEY_PWD=your_passphrase_here
SNOWFLAKE_KEY_PATH=C:/Users/YourName/.snowflake/rsa_key_POWERBISVC.p8
SNOWFLAKE_KEY_B64=
```

### Generating the base64 key for shinyapps.io

Run this once in R to encode your key file, then paste the output into the shinyapps.io `.Renviron`:

```r
key_bytes       <- readBin("C:/path/to/rsa_key_POWERBISVC.p8", what = "raw", n = 1e6)
key_bytes_clean <- key_bytes[key_bytes != as.raw(0x0d)]   # strip Windows \r bytes
cat(openssl::base64_encode(key_bytes_clean))
```

---

## Deployment

### Local

1. Clone the repo
2. Create a project-level `.Renviron` with the variables above (see `.Renviron.example`)
3. Restart R to load the environment variables
4. Run the app: `shiny::runApp()`

### shinyapps.io

1. Generate the base64 key string (see above) and add it to `.Renviron`
2. Deploy using `rsconnect::deployApp()` with explicit file list:

```r
rsconnect::deployApp(
  appDir   = "path/to/your/app",
  appFiles = c("app.R", "global.R", "snowflake_jwt.R", ".Renviron"),
  appName  = "your_app_name",
  forceUpdate = TRUE
)
```

> **Important:** always deploy using `deployApp()` with an explicit `appFiles` argument. The RStudio Publish button may miss `.Renviron` and helper files.

---

## Line Endings

This project targets Linux (shinyapps.io runs Ubuntu). All R files and `.Renviron` **must use Unix line endings (LF)**, not Windows line endings (CRLF).

**Recommended:** set your editor to use LF globally.

- **RStudio:** `Tools → Global Options → Code → Saving → Line ending conversion → Posix (LF)`
- **VSCode:** `Files: Eol → \n` in settings

If you need to fix line endings programmatically:

```r
# Fix a file's line endings in R
fix_line_endings <- function(path) {
  raw   <- readBin(path, what = "raw", n = 1e6)
  clean <- raw[raw != as.raw(0x0d)]
  writeBin(clean, path)
}

fix_line_endings("global.R")
fix_line_endings("snowflake_jwt.R")
fix_line_endings(".Renviron")
```

---

## Data Source

The app queries a single aggregated result from:

```
ROCKIT_DATA_PROD.COMPAC.STG_COMPAC_BATCH
```

The startup query returns sizing statistics for the current season:

```sql
SELECT
    AVG(MINOR)               AS MEAN_EQ
   ,STDDEV(MINOR)            AS SD_EQ
   ,AVG(MAJOR/MINOR)         AS MEAN_ELONG
   ,STDDEV(MAJOR/MINOR)      AS SD_ELONG
   ,AVG(WEIGHT)              AS MEAN_MASS
   ,STDDEV(WEIGHT)           AS SD_MASS
   ,COVAR_POP(MINOR, MAJOR/MINOR) AS COV
FROM ROCKIT_DATA_PROD.COMPAC.STG_COMPAC_BATCH
WHERE START_TIME  >  '2026-01-01 00:00:00.000'
  AND START_TIME  <= '2027-01-01 00:00:00.000'
  AND NOT (SIZER_GRADE_NAME IN (
        'Capture','Rcy','Capture ','Recycle',
        'Doub','Doubles ','Capt','Ai','Leaf','Cap'
      ))
  AND MINOR  >= 30
  AND MAJOR  >= 30
```

This returns a single row stored in the `compac_stats` object, available throughout the app.

---

## Dependencies

```r
install.packages(c(
  "shiny",
  "tidyverse",
  "openssl",
  "httr2",
  "jsonlite"   # usually installed as a dependency
))
```

`jose` is **not** required — JWT signing is implemented directly via `openssl` to avoid package masking conflicts with `httr2`.

---

## Security Notes

- `.Renviron` is excluded from git via `.gitignore` — never commit credentials
- The private key passphrase and base64 key are stored only in `.Renviron`
- The Snowflake service account (`POWERBISVC`) has read-only access to the required tables
- JWT tokens expire after 1 hour; a new token is generated for each app startup

---

## .gitignore

Ensure your `.gitignore` includes:

```
.Renviron
*.p8
*.pem
rsconnect/
```
