/* =========================================================================
   CONSUMER SIDE  ·  DCR Audience Overlap via Data Collaboration API
   -------------------------------------------------------------------------
   FINAL VERIFIED VERSION - semua step sudah dieksekusi sukses di akun
   SFSEAPAC.ALVIN_JKT terhadap collaboration 'telco_audience_overlap' milik
   provider SFSEAPAC.ARDIYANMUHAMMAD.

   Skenario historical + partitioned:
     - Provider C360_TELCO (1.2B rows, 8 weekly partitions)
     - Consumer MARKETING_AUDIENCE_DCR_DEMO (8M rows, 8 partitions)
     - Join key: HASHED_MSISDN (exposed sebagai HASHED_PHONE_SHA256 di shared view)
     - Partition matching via where_clause (bukan join_clauses) karena DATE_PARTITION
       wajib deklarasi `passthrough` (column_type 'dimension' TIDAK valid untuk
       join_standard - hanya PII types yang valid)

   Prerequisite:
     - DCR sudah terinstall (SAMOOHA_BY_SNOWFLAKE_LOCAL_DB)
     - User punya SAMOOHA_APP_ROLE (ACCOUNTADMIN cukup kalau role restricted)
     - MARKETING_AUDIENCE_DCR_DEMO populated
     - Provider sudah INITIALIZE collaboration
   ========================================================================= */

-- =========================================================================
-- STEP 0  ·  Session setup
-- =========================================================================
USE ROLE SAMOOHA_APP_ROLE;          -- skip kalau session PAT restricted ke ACCOUNTADMIN
USE WAREHOUSE GEN2_SMALL;

SELECT CURRENT_ORGANIZATION_NAME() || '.' || CURRENT_ACCOUNT_NAME() AS CURRENT_ACCOUNT;
-- Expected: SFSEAPAC.ALVIN_JKT

-- =========================================================================
-- STEP 1  ·  Grant akses DCR ke marketing_audience
-- -------------------------------------------------------------------------
-- CATATAN: GRANT REFERENCE_USAGE ... TO SHARE SAMOOHA_BY_SNOWFLAKE_APP_SHARE
-- adalah pattern legacy v1 / Native App - TIDAK ada di DCR Collaboration API v2.
-- =========================================================================
GRANT ROLE SAMOOHA_APP_ROLE TO USER <CONSUMER_USER>;

GRANT USAGE  ON DATABASE DCR_CONSUMER_1M        TO ROLE SAMOOHA_APP_ROLE;
GRANT USAGE  ON SCHEMA   DCR_CONSUMER_1M.DATA   TO ROLE SAMOOHA_APP_ROLE;
GRANT SELECT ON TABLE    DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO
       TO ROLE SAMOOHA_APP_ROLE;

-- =========================================================================
-- STEP 2  ·  Register built-in templates (WAJIB sebelum RUN)
-- -------------------------------------------------------------------------
-- Built-in templates tidak tersedia otomatis. Wajib register di consumer
-- (juga di provider).
-- =========================================================================
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.REGISTRY.REGISTER_STANDARD_DCR_TEMPLATES();

-- =========================================================================
-- STEP 3  ·  View invitation dari provider
-- =========================================================================
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.VIEW_COLLABORATIONS();
-- Cari baris:
--   SOURCE_NAME       = 'telco_audience_overlap'
--   OWNER_ACCOUNT     = 'SFSEAPAC.ARDIYANMUHAMMAD'
--   COLLABORATION_NAME = NULL  (belum di-review)

-- =========================================================================
-- STEP 4  ·  REVIEW invitation (non-owner wajib review dulu)
-- =========================================================================
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.REVIEW(
  'telco_audience_overlap',                 -- source_name
  'SFSEAPAC.ARDIYANMUHAMMAD',               -- owner_account (provider)
  'telco_audience_overlap'                  -- local_name
);

-- =========================================================================
-- STEP 5  ·  JOIN the collaboration
-- =========================================================================
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.JOIN('telco_audience_overlap');

-- Pantau status (tunggu sampai consumer status = JOINED)
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.GET_STATUS('telco_audience_overlap');

-- =========================================================================
-- STEP 6  ·  REGISTER local data offering
-- -------------------------------------------------------------------------
-- Kebijakan kolom:
--   HASHED_MSISDN  -> join_standard (hashed_phone_sha256), exposed di view
--                     sebagai kolom 'HASHED_PHONE_SHA256'
--   DATE_PARTITION -> passthrough (TIDAK boleh join_standard 'dimension' -
--                     hanya PII types yang valid untuk column_type)
--   CUSTOMER_TIER/SEGMENT/PROPENSITY/LAST_CAMPAIGN/CHANNEL_PREF -> passthrough
-- =========================================================================
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.REGISTRY.REGISTER_DATA_OFFERING($$
api_version: "2.0.0"
spec_type: data_offering
name: consumer_marketing_audience
version: "v1_0"
description: Consumer marketing audience historical (8 partitions x ~1M rows). Join key HASHED_MSISDN, partition match via DATE_PARTITION filter.

datasets:
  - alias: audience
    data_object_fqn: DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO
    allowed_analyses: template_only
    object_class: custom
    schema_and_template_policies:
      HASHED_MSISDN:    { category: join_standard, column_type: hashed_phone_sha256, activation_allowed: true }
      DATE_PARTITION:   { category: passthrough, activation_allowed: true }
      CUSTOMER_TIER:    { category: passthrough, activation_allowed: true }
      SEGMENT:          { category: passthrough, activation_allowed: true }
      PROPENSITY:       { category: passthrough, activation_allowed: true }
      LAST_CAMPAIGN:    { category: passthrough, activation_allowed: true }
      CHANNEL_PREF:     { category: passthrough, activation_allowed: true }
$$);

-- Link ke collaboration sebagai local offering
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.LINK_LOCAL_DATA_OFFERING(
  'telco_audience_overlap',
  'consumer_marketing_audience_v1_0'
);

-- =========================================================================
-- STEP 7  ·  Lihat template_view_names (CRITICAL untuk RUN)
-- -------------------------------------------------------------------------
-- Ambil nilai TEMPLATE_VIEW_NAME dari kolom ini:
--   · PARTNER: "PROVIDER.telco_c360_offering_v1_0.c360"    (prefix = collab alias)
--   · LOCAL  : "LOCAL.consumer_marketing_audience_v1_0.audience"
-- ANALYSIS_ALLOWED_COLUMNS = daftar kolom yang boleh di where/group
-- TEMPLATE_JOIN_COLUMNS    = daftar kolom yang boleh di join_clauses
--                            (muncul sebagai kolom column_type alias di shared view)
-- =========================================================================
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.VIEW_DATA_OFFERINGS('telco_audience_overlap');
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.VIEW_TEMPLATES('telco_audience_overlap');

-- =========================================================================
-- STEP 8  ·  RUN ANALYSIS -> hitung overlap SELURUH DATA (full-scan, 1 query)
-- -------------------------------------------------------------------------
-- PENTING - syntax rules yang perlu diperhatikan:
--   1. view_mappings.source_tables = ARRAY of strings (plural)
--      local_view_mappings.my_tables = ARRAY of strings (plural)
--   2. join_clauses PAKAI column_type ALIAS yang di-expose di shared view:
--      HASHED_PHONE_SHA256  (BUKAN HASHED_MSISDN nama asli)
--   3. DATE_PARTITION tidak bisa di join_clauses (karena passthrough).
--      Kalau mau scope ke 1 partisi, pakai my_where_clause + source_where_clause.
--   4. count_column juga pakai column_type alias, TANPA p1./c1. prefix.
--
-- MODE FULL-SCAN (recommended untuk production):
--   - my_where_clause & source_where_clause DIKOSONGKAN
--   - Satu RUN call memproses seluruh 1.2B provider × 8M consumer rows
--   - Benchmark: 57 detik di GEN2_XLARGE (vs 209 detik loop per-partisi)
--   - Output: k-anonymized overlap count across ALL partitions
--
-- Hasil uji single-partition (20260420) sebelumnya:
--   WATERFALL_LEVEL | METRIC_TYPE | COUNT_VALUE | TOTAL_COUNT
--   1               | OVERLAP     | 700,000     | 1,000,000
--   1               | NON_OVERLAP | 300,000     | 1,000,000
-- =========================================================================
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.RUN('telco_audience_overlap', $$
api_version: "2.0.0"
spec_type: "analysis"
name: "overlap_count_fullscan"
description: Hitung overlap untuk SELURUH data (semua partisi) dalam satu query
template: "standard_audience_overlap_v0"

template_configuration:
  view_mappings:
    source_tables:
      - "PROVIDER.telco_c360_offering_v1_0.c360"
  local_view_mappings:
    my_tables:
      - "LOCAL.consumer_marketing_audience_v1_0.audience"

  arguments:
    join_clauses:
      - "p1.HASHED_PHONE_SHA256 = c1.HASHED_PHONE_SHA256"
    count_column:
      - "HASHED_PHONE_SHA256"
    my_where_clause:     ""
    source_where_clause: ""
    my_group_by: []
    source_group_by: []
$$);

-- CATATAN POLICY (PENTING):
--   Composite join `p1.DATE_PARTITION = c1.DATE_PARTITION` DITOLAK oleh
--   standard template karena join_standard hanya menerima PII types
--   (hashed_phone_sha256, email, dll). DATE_PARTITION = passthrough.
--   Error: **FAILURE**: Unauthorized columns: p1.date_partition
--
-- Konsekuensi single-query tanpa partition filter:
--   - Output raw = cartesian expansion (MSISDN × 8 partisi × 8 partisi = 44.8M rows)
--   - Unique audience setelah DISTINCT = 3.37M tuples (identik dengan loop per-partisi)
--   - Benchmark: 57 detik analysis + 79 detik activation di GEN2_XLARGE (5× lebih cepat dari loop)
--
-- Opsi alternatif kalau butuh semantic composite (1 row per MSISDN per minggu):
--   (a) Per-partition loop — 8 RUN calls, masing-masing dengan filter:
--       my_where_clause:     "c1.DATE_PARTITION = 20260420"
--       source_where_clause: "p1.DATE_PARTITION = 20260420"
--   (b) Breakdown per partisi dalam 1 query (tetap cartesian tapi dikelompokkan):
--       my_group_by: ["c1.DATE_PARTITION"]
--       source_group_by: ["p1.DATE_PARTITION"]

-- =========================================================================
-- STEP 9  ·  RUN ACTIVATION -> export matched records (FULL COLUMNS + FULL-SCAN)
-- -------------------------------------------------------------------------
-- Hasil di-landing di schema share: SFDCR_TELCO_AUDIENCE_OVERLAP.ACTIVATION.
-- Tabel: SEGMENT_RECORDS  (kolom RECORDS berisi VARIANT dengan ID object).
--
-- USE CASE: kita butuh SELURUH 1000 kolom provider + seluruh kolom consumer
-- (~1007 keys per record) di-export untuk downstream ML / scoring / feature store.
--
-- GOTCHA: Spec YAML dengan 1000+ `activation_column` entries > 256 byte limit
-- session variable, jadi TIDAK BISA di-build via `SET X = (SELECT LISTAGG...)`.
--
-- SOLUSI: Snowflake Scripting anonymous block. Local `STRING` variable tidak
-- punya 256-byte limit, dan spec bisa di-bind sebagai argument ke CALL.
--
-- Discover dulu berapa kolom provider yang eligible untuk activation:
SELECT COUNT(DISTINCT COLUMN_NAME) AS PROVIDER_ACTIVATION_COLS
FROM SFDCR_TELCO_AUDIENCE_OVERLAP.CLEANROOM.POLICY_COLUMNS_V
WHERE ANALYSIS_NAME = 'standard_audience_overlap_activation_v0'
  AND TABLE_NAME LIKE '%C360_TELCO%';
-- Expected: 1000

-- =========================================================================
-- RUN ACTIVATION — 1007 kolom, 1 query single-call, dynamic spec via LISTAGG
-- =========================================================================
USE WAREHOUSE GEN2_XLARGE;  -- atau GEN2_2XLARGE untuk lebih cepat
ALTER WAREHOUSE GEN2_XLARGE RESUME IF SUSPENDED;

DECLARE
  consumer_lines STRING;
  provider_lines STRING;
  spec           STRING;
  result         VARIANT;
  t0             TIMESTAMP_LTZ;
  t1             TIMESTAMP_LTZ;
BEGIN
  -- Build consumer activation lines (exclude join key)
  SELECT LISTAGG('      - "c1.' || COLUMN_NAME || '"', '\n')
         WITHIN GROUP (ORDER BY ORDINAL_POSITION)
  INTO :consumer_lines
  FROM DCR_CONSUMER_1M.INFORMATION_SCHEMA.COLUMNS
  WHERE TABLE_SCHEMA='DATA' AND TABLE_NAME='MARKETING_AUDIENCE_DCR_DEMO'
    AND COLUMN_NAME NOT IN ('HASHED_MSISDN');

  -- Build provider activation lines from shared policy view
  SELECT LISTAGG('      - "p1.' || COLUMN_NAME || '"', '\n')
         WITHIN GROUP (ORDER BY COLUMN_NAME)
  INTO :provider_lines
  FROM (
    SELECT DISTINCT COLUMN_NAME
    FROM SFDCR_TELCO_AUDIENCE_OVERLAP.CLEANROOM.POLICY_COLUMNS_V
    WHERE ANALYSIS_NAME='standard_audience_overlap_activation_v0'
      AND TABLE_NAME LIKE '%C360_TELCO%'
      AND COLUMN_NAME NOT IN ('HASHED_MSISDN','HASHED_PHONE_SHA256')
  );

  spec := 'api_version: "2.0.0"
spec_type: "analysis"
name: "activate_overlap_fullcolumns"
description: Export matched audiens dengan SEMUA 1000 kolom provider + consumer.
template: "standard_audience_overlap_activation_v0"

template_configuration:
  view_mappings:
    source_tables:
      - "PROVIDER.telco_c360_offering_v1_0.c360"
  local_view_mappings:
    my_tables:
      - "LOCAL.consumer_marketing_audience_v1_0.audience"

  arguments:
    join_clauses:
      - "p1.HASHED_PHONE_SHA256 = c1.HASHED_PHONE_SHA256"
    activation_column:
' || :consumer_lines || '
' || :provider_lines || '
    where_clause: ""

  activation:
    snowflake_collaborator: "CONSUMER"
    segment_name: "telco_highvalue_fullcolumns"
';

  t0 := CURRENT_TIMESTAMP();
  CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.RUN('telco_audience_overlap', :spec) INTO :result;
  t1 := CURRENT_TIMESTAMP();

  RETURN OBJECT_CONSTRUCT(
    'spec_size_bytes', LENGTH(:spec),
    'elapsed_seconds', DATEDIFF('MILLISECOND', :t0, :t1) / 1000.0,
    'result',          :result
  );
END;

-- Benchmark hasil (dieksekusi di SFSEAPAC.ALVIN_JKT):
--   GEN2_XLARGE (16 cr/hr):  ~303 s wall = ~1.35 credits
--   GEN2_2XLARGE (32 cr/hr): lihat benchmark_results.md section "FULL-COLUMNS Activation 2XL"
-- =========================================================================

-- =========================================================================
-- STEP 10  ·  Query hasil activation
-- -------------------------------------------------------------------------
-- Hasil: 700,000 records (matched) di share SFDCR_TELCO_AUDIENCE_OVERLAP.
-- =========================================================================
SELECT COUNT(*) AS ACTIVATED_ROWS
FROM   SFDCR_TELCO_AUDIENCE_OVERLAP.ACTIVATION.SEGMENT_RECORDS;

-- Inspect struktur (RECORDS adalah VARIANT):
SELECT TO_JSON(RECORDS) FROM SFDCR_TELCO_AUDIENCE_OVERLAP.ACTIVATION.SEGMENT_RECORDS LIMIT 3;

-- =========================================================================
-- STEP 11  ·  Materialize flat table di akun consumer (+ DEDUPLIKASI)
-- -------------------------------------------------------------------------
-- Untuk 1000+ kolom, materialization juga harus dibuild dinamis.
-- Dua pendekatan:
--   (a) Flat dinamis via Python - loop kolom + generate CREATE TABLE AS SELECT.
--       Script: ./helpers/materialize_activation_full_columns.py
--   (b) Simpan sebagai VARIANT dan parse on-demand di downstream query.
--
-- Contoh pendekatan (b) - simpan VARIANT utuh + 1 filter segment_name:
-- =========================================================================
CREATE OR REPLACE TABLE DCR_CONSUMER_1M.DATA.ACTIVATION_TELCO_FULLCOLUMNS_RAW
AS
SELECT DISTINCT
    RECORDS,
    BATCH_ID,
    SEGMENT_NAME,
    UPDATED_ON
FROM SFDCR_TELCO_AUDIENCE_OVERLAP.ACTIVATION.SEGMENT_RECORDS
WHERE SEGMENT_NAME = 'telco_highvalue_fullcolumns';

SELECT COUNT(*) AS TOTAL_UNIQUE_RECORDS FROM DCR_CONSUMER_1M.DATA.ACTIVATION_TELCO_FULLCOLUMNS_RAW;

-- Inspect struktur VARIANT (akan ada ~1005 keys):
SELECT ARRAY_SIZE(OBJECT_KEYS(RECORDS:ID)) AS COLUMN_COUNT_PER_RECORD
FROM   DCR_CONSUMER_1M.DATA.ACTIVATION_TELCO_FULLCOLUMNS_RAW LIMIT 1;

-- Preview beberapa kolom (tambahkan sesuai kebutuhan downstream):
SELECT
    RECORDS:ID:"p1.DATE_PARTITION"::NUMBER(8,0) AS DATE_PARTITION,
    RECORDS:ID:"c1.CUSTOMER_TIER"::STRING       AS CUSTOMER_TIER,
    RECORDS:ID:"c1.SEGMENT"::STRING             AS SEGMENT,
    RECORDS:ID:"p1.AGE"::NUMBER                 AS AGE,
    RECORDS:ID:"p1.GENDER"::STRING              AS GENDER,
    RECORDS:ID:"p1.CHURN_SCORE"::FLOAT          AS CHURN_SCORE,
    RECORDS:ID:"p1.CLV_SCORE"::FLOAT            AS CLV_SCORE,
    RECORDS:ID:"p1.IS_HIGH_VALUE"::BOOLEAN      AS IS_HIGH_VALUE
FROM DCR_CONSUMER_1M.DATA.ACTIVATION_TELCO_FULLCOLUMNS_RAW
LIMIT 10;

-- Kalau butuh FLAT TABLE 1005 kolom (storage lebih besar, query lebih cepat):
--   Jalankan: SNOWFLAKE_CONNECTION_NAME=alvin-putra-aws-jkt \
--              /tmp/sfenv/bin/python ./helpers/materialize_activation_full_columns.py
-- Script akan auto-generate CREATE OR REPLACE TABLE AS SELECT dengan 1005 cast.

-- Preview:
SELECT DATE_PARTITION, CUSTOMER_TIER, SEGMENT, PROPENSITY, LAST_CAMPAIGN, CHANNEL_PREF
FROM   DCR_CONSUMER_1M.DATA.ACTIVATION_TELCO_HIGHVALUE
LIMIT 10;

-- =========================================================================
-- DONE - end-to-end DCR Audience Overlap via Collaboration API v2 completed.
-- =========================================================================
