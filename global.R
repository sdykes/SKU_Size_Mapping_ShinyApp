# global.R
source("snowflake_jwt.R")

sql_compac_stats <- "
SELECT
    AVG(MINOR)          AS MEAN_EQ
   ,STDDEV(MINOR)       AS SD_EQ
   ,AVG(MAJOR/MINOR)    AS MEAN_ELONG
   ,STDDEV(MAJOR/MINOR) AS SD_ELONG
   ,AVG(WEIGHT)         AS MEAN_MASS
   ,STDDEV(WEIGHT)      AS SD_MASS
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
"

message("[global.R] Querying Snowflake...")
ApplePopSizeStats <- tryCatch(
  snowflake_query(sql_compac_stats),
  error = function(e) {
    message("[global.R] Snowflake query failed: ", conditionMessage(e))
    NULL
  }
)

if (!is.null(ApplePopSizeStats)) {
  message("[global.R] Query succeeded.")
  #print(ApplePopSizeStats)
} else {
  message("[global.R] Using NULL fallback — check credentials and network.")
}
