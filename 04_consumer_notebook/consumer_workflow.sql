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
-- STEP 8  ·  RUN ANALYSIS -> hitung overlap per partisi
-- -------------------------------------------------------------------------
-- PENTING - syntax rules yang perlu diperhatikan:
--   1. view_mappings.source_tables = ARRAY of strings (plural)
--      local_view_mappings.my_tables = ARRAY of strings (plural)
--   2. join_clauses PAKAI column_type ALIAS yang di-expose di shared view:
--      HASHED_PHONE_SHA256  (BUKAN HASHED_MSISDN nama asli)
--   3. DATE_PARTITION tidak bisa di join_clauses (karena passthrough).
--      Gunakan my_where_clause + source_where_clause untuk scope partisi.
--   4. count_column juga pakai column_type alias, TANPA p1./c1. prefix.
--
-- Hasil uji:
--   WATERFALL_LEVEL | METRIC_TYPE | COUNT_VALUE | TOTAL_COUNT
--   1               | OVERLAP     | 700,000     | 1,000,000
--   1               | NON_OVERLAP | 300,000     | 1,000,000
-- =========================================================================
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.RUN('telco_audience_overlap', $$
api_version: "2.0.0"
spec_type: "analysis"
name: "overlap_count"
description: Hitung audiens consumer yang match dengan C360 provider pada partisi terbaru
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
    my_where_clause:     "c1.DATE_PARTITION = 20260420"
    source_where_clause: "p1.DATE_PARTITION = 20260420"
    my_group_by: []
    source_group_by: []
$$);

-- Opsi alternatif: hilangkan where_clause dan tambahkan DATE_PARTITION di
-- my_group_by + source_group_by untuk breakdown per partisi.

-- =========================================================================
-- STEP 9  ·  RUN ACTIVATION -> export matched records
-- -------------------------------------------------------------------------
-- Hasil di-landing di schema share: SFDCR_TELCO_AUDIENCE_OVERLAP.ACTIVATION.
-- Tabel: SEGMENT_RECORDS  (kolom RECORDS berisi VARIANT dengan ID object).
-- =========================================================================
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.RUN('telco_audience_overlap', $$
api_version: "2.0.0"
spec_type: "analysis"
name: "activate_overlap_segment"
description: Export matched audiens (partisi terbaru) ke akun consumer untuk campaign targeting.
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
      - "c1.CUSTOMER_TIER"
      - "c1.SEGMENT"
      - "c1.PROPENSITY"
      - "c1.LAST_CAMPAIGN"
      - "c1.CHANNEL_PREF"
      - "p1.DATE_PARTITION"
    where_clause: "p1.DATE_PARTITION = 20260420 AND c1.DATE_PARTITION = 20260420"

  activation:
    snowflake_collaborator: "CONSUMER"
    segment_name: "telco_highvalue_overlap_v1"
$$);

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
-- STEP 11  ·  Materialize flat table di akun consumer (permanen)
-- -------------------------------------------------------------------------
-- Parse VARIANT -> kolom terstruktur, cluster by DATE_PARTITION.
-- =========================================================================
CREATE OR REPLACE TABLE DCR_CONSUMER_1M.DATA.ACTIVATION_TELCO_HIGHVALUE
CLUSTER BY (DATE_PARTITION) AS
SELECT
    RECORDS:ID:"p1.DATE_PARTITION"::NUMBER(8,0)  AS DATE_PARTITION,
    RECORDS:ID:"c1.CUSTOMER_TIER"::STRING        AS CUSTOMER_TIER,
    RECORDS:ID:"c1.SEGMENT"::STRING              AS SEGMENT,
    RECORDS:ID:"c1.PROPENSITY"::FLOAT            AS PROPENSITY,
    RECORDS:ID:"c1.LAST_CAMPAIGN"::STRING        AS LAST_CAMPAIGN,
    RECORDS:ID:"c1.CHANNEL_PREF"::STRING         AS CHANNEL_PREF,
    RECORDS:ID:"join_clause"::STRING             AS MATCH_CRITERIA,
    BATCH_ID,
    SEGMENT_NAME,
    UPDATED_ON
FROM SFDCR_TELCO_AUDIENCE_OVERLAP.ACTIVATION.SEGMENT_RECORDS;

SELECT COUNT(*) AS TOTAL_ACTIVATED,
       COUNT(DISTINCT DATE_PARTITION) AS PARTITIONS
FROM DCR_CONSUMER_1M.DATA.ACTIVATION_TELCO_HIGHVALUE;
-- Expected: 700,000 rows, 1 partition (20260420)

-- Preview:
SELECT DATE_PARTITION, CUSTOMER_TIER, SEGMENT, PROPENSITY, LAST_CAMPAIGN, CHANNEL_PREF
FROM   DCR_CONSUMER_1M.DATA.ACTIVATION_TELCO_HIGHVALUE
LIMIT 10;

-- =========================================================================
-- DONE - end-to-end DCR Audience Overlap via Collaboration API v2 completed.
-- =========================================================================
