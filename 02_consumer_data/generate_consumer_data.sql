-- =====================================================================
-- Consumer data generator (HISTORICAL / PARTITIONED)
-- Target table: DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO
-- Schema:
--   DATE_PARTITION  NUMBER(8,0)   -- YYYYMMDD (MATCH provider values)
--   HASHED_MSISDN   STRING        -- join key (SHA-256), stabil antar partisi
--   CUSTOMER_TIER   STRING        -- attribute 1
--   SEGMENT         STRING        -- attribute 2
--   PROPENSITY      FLOAT         -- attribute 3
--   LAST_CAMPAIGN   STRING        -- attribute 4
--   CHANNEL_PREF    STRING        -- attribute 5
-- Clustering: CLUSTER BY (DATE_PARTITION)
--
-- Ukuran:
--   ~1,000,000 rows per partition x 8 partitions = 8,000,000 rows total
--   Per partisi:
--     - 700,000 rows OVERLAP dengan provider (seed 0..699,999)
--       -> SHA2('628' || LPAD(seed,10,'0'), 256) sama dengan provider
--     - 300,000 rows NON-OVERLAP (seed 150,000,000..150,299,999)
--       -> di luar range provider (provider seed = 0..149,999,999)
--
-- Eksekusi: JANGAN dijalankan otomatis. User akan eksekusi manual di akun consumer.
-- Disarankan warehouse X-SMALL..LARGE (cukup untuk 8M rows).
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE <CONSUMER_WAREHOUSE>;   -- ganti sesuai warehouse consumer

CREATE DATABASE IF NOT EXISTS DCR_CONSUMER_1M;
CREATE SCHEMA   IF NOT EXISTS DCR_CONSUMER_1M.DATA;
USE SCHEMA DCR_CONSUMER_1M.DATA;

-- ---------------------------------------------------------------------
-- 1) Buat tabel baru (DCR demo). Tidak mengganggu MARKETING_AUDIENCE asli.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO (
    DATE_PARTITION  NUMBER(8,0),
    HASHED_MSISDN   STRING,
    CUSTOMER_TIER   STRING,
    SEGMENT         STRING,
    PROPENSITY      FLOAT,
    LAST_CAMPAIGN   STRING,
    CHANNEL_PREF    STRING
)
CLUSTER BY (DATE_PARTITION);

-- ---------------------------------------------------------------------
-- 2) Populate per-partition (OVERLAP 700k + NON-OVERLAP 300k)
--    Catatan:
--      - SEQ8() di GENERATOR mulai dari 0 dalam satu query.
--      - OVERLAP seed range: 0..699,999          -> match dengan provider
--      - NON-OVERLAP seed  : 150,000,000 + 0..299,999
--        (di atas provider range max 149,999,999) -> tidak match
-- ---------------------------------------------------------------------

-- Helper macro pola insert (diulang per partisi)
-- =====================================================================
-- Partition 20260302
-- =====================================================================
INSERT INTO DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO
SELECT
    20260302 AS DATE_PARTITION,
    SHA2('628' || LPAD(SEQ8()::STRING, 10, '0'), 256) AS HASHED_MSISDN,
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING AS CUSTOMER_TIER,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING AS SEGMENT,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT AS PROPENSITY,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING AS LAST_CAMPAIGN,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING AS CHANNEL_PREF
FROM TABLE(GENERATOR(ROWCOUNT => 700000))
UNION ALL
SELECT
    20260302,
    SHA2('628' || LPAD((150000000 + SEQ8())::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 300000));

-- =====================================================================
-- Partition 20260309
-- =====================================================================
INSERT INTO DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO
SELECT
    20260309,
    SHA2('628' || LPAD(SEQ8()::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 700000))
UNION ALL
SELECT
    20260309,
    SHA2('628' || LPAD((150000000 + SEQ8())::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 300000));

-- =====================================================================
-- Partition 20260316
-- =====================================================================
INSERT INTO DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO
SELECT
    20260316,
    SHA2('628' || LPAD(SEQ8()::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 700000))
UNION ALL
SELECT
    20260316,
    SHA2('628' || LPAD((150000000 + SEQ8())::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 300000));

-- =====================================================================
-- Partition 20260323
-- =====================================================================
INSERT INTO DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO
SELECT
    20260323,
    SHA2('628' || LPAD(SEQ8()::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 700000))
UNION ALL
SELECT
    20260323,
    SHA2('628' || LPAD((150000000 + SEQ8())::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 300000));

-- =====================================================================
-- Partition 20260330
-- =====================================================================
INSERT INTO DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO
SELECT
    20260330,
    SHA2('628' || LPAD(SEQ8()::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 700000))
UNION ALL
SELECT
    20260330,
    SHA2('628' || LPAD((150000000 + SEQ8())::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 300000));

-- =====================================================================
-- Partition 20260406
-- =====================================================================
INSERT INTO DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO
SELECT
    20260406,
    SHA2('628' || LPAD(SEQ8()::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 700000))
UNION ALL
SELECT
    20260406,
    SHA2('628' || LPAD((150000000 + SEQ8())::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 300000));

-- =====================================================================
-- Partition 20260413
-- =====================================================================
INSERT INTO DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO
SELECT
    20260413,
    SHA2('628' || LPAD(SEQ8()::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 700000))
UNION ALL
SELECT
    20260413,
    SHA2('628' || LPAD((150000000 + SEQ8())::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 300000));

-- =====================================================================
-- Partition 20260420
-- =====================================================================
INSERT INTO DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO
SELECT
    20260420,
    SHA2('628' || LPAD(SEQ8()::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 700000))
UNION ALL
SELECT
    20260420,
    SHA2('628' || LPAD((150000000 + SEQ8())::STRING, 10, '0'), 256),
    ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum')[UNIFORM(0,3,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Young Pro','Family','Senior','Student','Traveler')[UNIFORM(0,4,RANDOM())]::STRING,
    ROUND(UNIFORM(0, 10000, RANDOM())/10000.0, 4)::FLOAT,
    ARRAY_CONSTRUCT('CAMP_SUMMER','CAMP_HOLIDAY','CAMP_LOYALTY','CAMP_WINBACK','CAMP_UPSELL')[UNIFORM(0,4,RANDOM())]::STRING,
    ARRAY_CONSTRUCT('Email','SMS','Push','InApp','Call')[UNIFORM(0,4,RANDOM())]::STRING
FROM TABLE(GENERATOR(ROWCOUNT => 300000));

-- ---------------------------------------------------------------------
-- 3) Sanity checks
-- ---------------------------------------------------------------------
SELECT DATE_PARTITION, COUNT(*) AS ROW_COUNT
FROM DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO
GROUP BY 1 ORDER BY 1;

SELECT COUNT(*) AS TOTAL_ROWS
FROM DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO;

SELECT SYSTEM$CLUSTERING_INFORMATION(
    'DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO',
    '(DATE_PARTITION)'
);
