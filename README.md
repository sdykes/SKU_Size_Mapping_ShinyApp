# Rockit SKU Simulation App

A Shiny application for apple sizing analysis and SKU simulation. It models the
bivariate size distribution of Rockit apples using parameters derived from live
Compac grader data, and simulates how that population distributes across SKUs
given a configurable bin-split configuration.

---

## Architecture

```
app.R
 ├── source("global.R")             # Snowflake query — runs once at startup
 │    └── source("snowflake_jwt.R") # JWT auth + SQL API helper
 └── source("bin_splits_module.R")  # Shiny module: bin editor + SKU probabilities

bin_grid_labelled.csv              # 12×12 bin grid with SKU assignments
bin_mass_lookup.csv                # Mean fruit mass per bin cell
```

---

## File Overview

| File | Purpose |
|------|---------|
| `app.R` | Main Shiny app — UI layout, server logic, batch analysis |
| `global.R` | Runs once at startup; queries Snowflake and creates `compac_stats` |
| `snowflake_jwt.R` | Self-contained helper: builds RSA/JWT token, calls Snowflake SQL API |
| `bin_splits_module.R` | Shiny module: interactive bin split editor and SKU probability engine |
| `bin_grid_labelled.csv` | 144-cell (12×12) Compac grader bin grid with SKU assignments |
| `bin_mass_lookup.csv` | Mean fruit mass (g) lookup by equatorial diameter × elongation bin |
| `.Renviron` | Credentials — excluded from git |

---

## Application Overview

The app has three main tabs:

### 1. Underlying distribution plot
Visualises 1 million simulated apple measurements drawn from a bivariate normal
distribution parameterised by:

| Parameter | Description |
|-----------|-------------|
| Mean equatorial diameter | Mean EQ diameter (mm) |
| SD equatorial diameter | Standard deviation of EQ diameter |
| Mean elongation | Mean elongation ratio (major/minor) |
| SD elongation | Standard deviation of elongation |
| Covariance | Covariance between EQ diameter and elongation |

All five parameters default to values computed from the live Snowflake query at
startup. A **Reset to defaults** button restores them.

### 2. Bin splits
The interactive bin split editor — see [Bin Splits Module](#bin-splits-module) below.

### 3. Batch analysis
Given a batch input (kg or number of bins) and a packout percentage, computes
expected RWEs (kg) per SKU using the mass-weighted SKU probability distribution
from the current bin split configuration. Results are displayed as a `gt` table
and a bar chart, and can be exported as CSV.

---

## Bin Splits Module

**File:** `bin_splits_module.R`  
**Module ID:** `"bins"` (called as `binSplitUI("bins")` / `binSplitServer("bins", mean_vec, cov_mat)`)

### Purpose

The Compac grader assigns each apple to one of 144 bins defined by a 12×12 grid
of equatorial diameter (EQ) × elongation index. Many bins are assigned to a
single SKU; others span multiple SKUs and require a proportional split to be
defined. This module provides an interactive interface for editing those splits
and computing the resulting SKU probability distribution.

### Input data

#### `bin_grid_labelled.csv`
One row per bin cell. Key columns:

| Column | Description |
|--------|-------------|
| `bin_id` | Unique integer bin identifier |
| `EQBins` | Equatorial diameter bin label (e.g. `63 M`, `67`, `OS`) |
| `TomraElongBins` | Elongation index (0–11) |
| `EQCutsLow` / `EQCutsHigh` | EQ diameter cut boundaries (mm) |
| `ElongBreaksLow` / `ElongBreaksHigh` | Elongation cut boundaries |
| `SKU`, `SKU2`, `SKU3`, `SKU4` | Up to four SKUs assigned to the bin |

Bins are classified at load time as:
- **Single-SKU** — one SKU, no split needed
- **Multi-SKU** — two or more SKUs, proportional split is user-configurable
- **Unassigned** — no SKU (e.g. undersize / oversize / reject)

#### `bin_mass_lookup.csv`
Mean fruit mass (g) per elongation × EQ bin combination. Used to compute
mass-weighted SKU probabilities alongside count-weighted probabilities.

### Module interface

```r
# UI
binSplitUI("bins")

# Server — returns a list with two reactives
module_out <- binSplitServer("bins", mean_vec = mu, cov_mat = sigma)
bin_splits <- module_out$splits     # named list of split proportions per bin
sku_probs  <- module_out$sku_probs  # data frame: SKU, p_SKU, mw_SKU
```

**Inputs:**
- `mean_vec` — reactive returning `c(meanEQ, meanElong)`
- `cov_mat` — reactive returning the 2×2 covariance matrix

**Returns:**
- `splits` — reactive named list; keys are bin IDs (as character), values are
  named numeric vectors of proportions summing to 1  
  e.g. `splits$"29" = c("Daily small" = 0.40, "SFP" = 0.35, "63/5N" = 0.25)`
- `sku_probs` — reactive data frame with columns `SKU`, `p_SKU` (count-weighted),
  `mw_SKU` (mass-weighted)

### Tabs within the module

#### Split editor
- **Left panel:** 12×12 bin assignment grid rendered as a ggplot2 heatmap.
  Colour indicates primary SKU; opacity indicates bin type (multi-SKU bins are
  fully opaque, single-SKU bins are semi-transparent, unassigned bins are near-
  invisible). Click any solid (multi-SKU) bin to select it.
- **Right panel:** Slider controls for the selected bin's SKU proportions.
  Moving one slider automatically rescales the others to maintain a total of
  100% using proportional redistribution. A live percentage label sits beside
  each slider.
- **Save / Load config:** Download the current split configuration as an `.rds`
  file, or load a previously saved configuration. Loading is validated against
  the current bin grid.

#### Split summary
A tabular view of all 144 bins showing bin ID, EQ bin, elongation index, bin
type, and the proportion assigned to each SKU formatted as percentages.

#### SKU probabilities
Shows the expected probability of a randomly selected apple being packed into
each SKU, given the current distribution parameters and bin split configuration.
Two probability measures are shown:

| Measure | Description |
|---------|-------------|
| Count-weighted | P(apple → SKU) based on bivariate normal probabilities |
| Mass-weighted | As above, but weighted by mean fruit mass per bin |

Both are shown as **% of all fruit** (including undersize, oversize, and
unassigned) and **% of packed fruit** (excluding those categories). Undersize,
oversize and other unassigned bins are shown as footer rows.

Results can be exported as CSV.

### Probability calculation

For each bin cell the probability of an apple falling in that cell is computed
using the bivariate normal CDF via `mvtnorm::pmvnorm()`:

```r
prob <- mvtnorm::pmvnorm(
  lower = c(eq_low,  el_low),
  upper = c(eq_high, el_high),
  mean  = mean_vec,   # c(meanEQ, meanElong)
  sigma = cov_mat     # 2×2 covariance matrix
)
```

For multi-SKU bins, the bin probability is multiplied by each SKU's split
proportion to get the per-SKU contribution. Mass-weighted probability is
computed as `p_bin × mean_mass_g`, then similarly split. All bin contributions
are summed by SKU to produce the final distribution.

### SKU colour scheme

```r
SKU_COLORS <- c(
  "Daily small" = "#1D9E75",  "Daily large" = "#0F6E56",
  "SFP"         = "#378ADD",  "LFP"         = "#185FA5",
  "63/5N"       = "#7F77DD",  "Xlarge"      = "#D4537E",
  "MB SNS"      = "#BA7517",  "MB LNS"      = "#854F0B",
  "MB XLNS"     = "#633806"
)
```

### Default splits

Multi-SKU bins default to equal proportions unless overridden in `DEFAULT_SPLITS`
at the top of `bin_splits_module.R`:

```r
DEFAULT_SPLITS <- list(
  # "29" = c("Daily small" = 0.40, "SFP" = 0.35, "63/5N" = 0.25),
  # "42" = c("SFP" = 0.50, "LFP" = 0.50)
)
```

Keys are bin IDs as character strings; values are named numeric vectors (need
not sum to 1 — they are normalised at startup).

---

## Authentication

The app authenticates to Snowflake using **RSA key-pair / JWT authentication**
via the [Snowflake SQL API v2](https://docs.snowflake.com/en/developer-guide/sql-api/index).
This avoids the need for ODBC drivers, which are not available on shinyapps.io.

The JWT is built manually using only the `openssl` and `httr2` R packages — no
`jose` dependency — to avoid package masking conflicts on the deployment server.

### How it works

1. The private key is read from disk (local) or decoded from a base64
   environment variable (shinyapps.io)
2. A SHA256 fingerprint of the public key is computed using `write_der()` +
   `sha256()` + `base64_encode()`
3. A JWT is constructed with `iss`, `sub`, `iat`, `exp` claims and signed
   with `rsa_sign()`
4. The JWT is sent as a Bearer token in the `Authorization` header to the
   Snowflake SQL API
5. The response JSON is parsed into a data frame

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `SNOWFLAKE_KEY_PWD` | Passphrase for the encrypted private key file |
| `SNOWFLAKE_KEY_PATH` | Path to the `.p8` key file — **local only** |
| `SNOWFLAKE_KEY_B64` | Base64-encoded key file contents — **shinyapps.io only** |

### Local `.Renviron` example

```
SNOWFLAKE_KEY_PWD=your_passphrase_here
SNOWFLAKE_KEY_PATH=C:/Users/YourName/.snowflake/rsa_key_POWERBISVC.p8
SNOWFLAKE_KEY_B64=
```

### Generating the base64 key for shinyapps.io

```r
key_bytes       <- readBin("C:/path/to/rsa_key_POWERBISVC.p8", what = "raw", n = 1e6)
key_bytes_clean <- key_bytes[key_bytes != as.raw(0x0d)]   # strip Windows \r bytes
cat(openssl::base64_encode(key_bytes_clean))
```

---

## Deployment

### Local

1. Clone the repo
2. Create a project-level `.Renviron` with the variables above
3. Restart R
4. Run: `shiny::runApp()`

### shinyapps.io

```r
rsconnect::deployApp(
  appDir      = "path/to/your/app",
  appFiles    = c("app.R", "global.R", "snowflake_jwt.R",
                  "bin_splits_module.R",
                  "bin_grid_labelled.csv", "bin_mass_lookup.csv",
                  ".Renviron"),
  appName     = "your_app_name",
  forceUpdate = TRUE
)
```

> Always use `deployApp()` with an explicit `appFiles` list. The RStudio Publish
> button may miss `.Renviron` and helper files.

---

## Line Endings

All files must use Unix line endings (LF). Set in RStudio via:
`Tools → Global Options → Code → Saving → Line ending conversion → Posix (LF)`

---

## Dependencies

```r
install.packages(c(
  "shiny", "bslib", "bsicons",
  "tidyverse",
  "openssl", "httr2", "jsonlite",
  "mvtnorm",
  "gt", "scales", "glue",
  "base64enc", "MASS"
))
```

`jose` is **not** required.

---

## Data Source

```
ROCKIT_DATA_PROD.COMPAC.STG_COMPAC_BATCH
```

Startup query (single aggregated row):

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

Update the date range at the start of each season.

---

## Security Notes

- `.Renviron` is excluded from git — never commit credentials
- The service account (`POWERBISVC`) has read-only access
- JWT tokens expire after 1 hour; a new token is generated at each app startup

---

## .gitignore

```
.Renviron
*.p8
*.pem
rsconnect/
```
