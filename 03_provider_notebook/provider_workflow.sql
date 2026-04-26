/* =========================================================================
   PROVIDER SIDE  ·  DCR Audience Overlap via Data Collaboration API
   -------------------------------------------------------------------------
   Skenario (UPDATED - historical C360):
     - Provider punya C360_TELCO HISTORICAL (1.2B rows x 1001 cols) di
       DCR_POC_1M.PROVIDER_DATA.
         * 150M rows per partition x 8 weekly partitions (2 bulan)
         * CLUSTER BY (DATE_PARTITION)
     - Join keys (composite):
         HASHED_MSISDN  -> join_standard (hashed_phone_sha256)
         DATE_PARTITION -> join_standard (dimension) - match per partisi
     - Provider share SEMUA kolom lain (termasuk HASHED_EMAIL) sebagai
       passthrough + activation_allowed=true.
     - Built-in templates:
         standard_audience_overlap_v0             -> count overlap
         standard_audience_overlap_activation_v0  -> export segment
       Consumer WAJIB filter analisis per DATE_PARTITION agar match
       temporal tepat (mis. partisi mingguan terakhir).

   Prerequisite:
     - DCR environment sudah terinstall (SAMOOHA_BY_SNOWFLAKE_LOCAL_DB)
     - Tabel C360_TELCO sudah di-populate (8 partisi)
     - SAMOOHA_APP_ROLE sudah granted ke user
   ========================================================================= */

-- =========================================================================
-- STEP 0  ·  Session setup
-- =========================================================================
USE ROLE SAMOOHA_APP_ROLE;
USE WAREHOUSE GEN2_SMALL;
USE DATABASE DCR_POC_1M;
USE SCHEMA   PROVIDER_DATA;

-- Identitas akun provider (akan dipakai sebagai collaborator alias)
SELECT CURRENT_ORGANIZATION_NAME() || '.' || CURRENT_ACCOUNT_NAME() AS PROVIDER_ACCOUNT;
-- Contoh hasil: SFSEAPAC.ARDIYANMUHAMMAD
-- Ganti <PROVIDER_ACCOUNT> dan <CONSUMER_ACCOUNT> di STEP 4 di bawah.

-- =========================================================================
-- STEP 1  ·  Grant akses DCR ke tabel sumber
-- -------------------------------------------------------------------------
-- CATATAN: grant REFERENCE_USAGE ON DATABASE ... TO SHARE
-- SAMOOHA_BY_SNOWFLAKE_APP_SHARE dari v1 / native app tidak dipakai lagi di v2.
-- =========================================================================
GRANT ROLE SAMOOHA_APP_ROLE TO USER <USER>;

GRANT USAGE  ON DATABASE DCR_POC_1M               TO ROLE SAMOOHA_APP_ROLE;
GRANT USAGE  ON SCHEMA   DCR_POC_1M.PROVIDER_DATA TO ROLE SAMOOHA_APP_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA DCR_POC_1M.PROVIDER_DATA TO ROLE SAMOOHA_APP_ROLE;

-- =========================================================================
-- STEP 2  ·  Register Data Offering (HISTORICAL C360)
-- -------------------------------------------------------------------------
-- CATATAN PERBAIKAN (hasil eksekusi):
--   · Spec YAML > 256 bytes → tidak bisa dibuild via LISTAGG ke session
--     variable. Harus dibangun di Python / client dan dikirim sebagai arg.
--     Alternatif di SQL: gunakan CREATE TEMP TABLE berisi YAML sebagai teks,
--     lalu ambil via subquery saat CALL.
--   · column_type valid hanya untuk PII identifier (email/phone/device_id/
--     ip_address/first_name/last_name dan turunan hashed_* mereka).
--     DATE_PARTITION bukan identifier → ubah jadi PASSTHROUGH
--     (matching temporal diterapkan di join_clauses runtime).
--
-- Kebijakan final:
--   · HASHED_MSISDN  -> join_standard (hashed_phone_sha256), activation_allowed=false
--   · DATE_PARTITION -> passthrough, activation_allowed=true
--   · Kolom lain (999, termasuk HASHED_EMAIL) -> passthrough, activation_allowed=true
-- =========================================================================
-- Eksekusi REGISTER_DATA_OFFERING dilakukan via Python script
-- (membangun policies YAML untuk 1000 kolom passthrough):
--   /tmp/dcr_provider_step2.py
-- Isinya memanggil:
--   CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.REGISTRY.REGISTER_DATA_OFFERING(<spec>);
--
-- Sketsa spec (untuk referensi, bukan dieksekusi langsung):
/*
api_version: "2.0.0"
spec_type: data_offering
name: telco_c360_offering
version: "v1_0"
description: Telco C360 historical, composite join key HASHED_MSISDN + DATE_PARTITION.
datasets:
  - alias: c360
    data_object_fqn: DCR_POC_1M.PROVIDER_DATA.C360_TELCO
    allowed_analyses: template_only
    object_class: custom
    schema_and_template_policies:
      HASHED_MSISDN:  { category: join_standard, column_type: hashed_phone_sha256, activation_allowed: false }
      DATE_PARTITION: { category: passthrough, activation_allowed: true }
      <semua kolom lain>: { category: passthrough, activation_allowed: true }
*/

-- Verifikasi
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.REGISTRY.VIEW_REGISTERED_DATA_OFFERINGS();

-- =========================================================================
-- STEP 3  ·  Register standard DCR templates (WAJIB sebelum INITIALIZE)
-- -------------------------------------------------------------------------
-- Built-in templates standard_audience_overlap_v0 dan
-- standard_audience_overlap_activation_v0 TIDAK tersedia otomatis.
-- Harus di-register via REGISTER_STANDARD_DCR_TEMPLATES().
-- =========================================================================
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.REGISTRY.REGISTER_STANDARD_DCR_TEMPLATES();
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.REGISTRY.VIEW_REGISTERED_TEMPLATES();

-- =========================================================================
-- STEP 4  ·  Initialize Collaboration
-- -------------------------------------------------------------------------
-- Collaborators:
--   PROVIDER = SFSEAPAC.ARDIYANMUHAMMAD (owner + data provider)
--   CONSUMER = SFSEAPAC.ALVIN_JKT      (analysis runner + activation destination)
-- Owner akan auto-join setelah creation selesai (2-4 menit).
-- =========================================================================
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.INITIALIZE($$
api_version: "2.0.0"
spec_type: collaboration
name: telco_audience_overlap
description: Telco provider shares C360 to consumer for audience overlap and activation.

collaborator_identifier_aliases:
  PROVIDER: SFSEAPAC.ARDIYANMUHAMMAD
  CONSUMER: SFSEAPAC.ALVIN_JKT

owner: PROVIDER

analysis_runners:
  CONSUMER:
    data_providers:
      PROVIDER:
        data_offerings:
          - id: telco_c360_offering_v1_0
    templates:
      - id: standard_audience_overlap_v0
      - id: standard_audience_overlap_activation_v0
    activation_destinations:
      snowflake_collaborators:
        - CONSUMER
$$, 'GEN2_SMALL');

-- =========================================================================
-- STEP 5  ·  Monitor status
-- -------------------------------------------------------------------------
-- Status owner akan auto-join setelah CREATING selesai. Consumer tetap
-- INVITED sampai mereka REVIEW & JOIN dari sisi mereka.
-- =========================================================================
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.GET_STATUS('telco_audience_overlap');
-- Tunggu hingga PROVIDER status = JOINED dan CONSUMER = INVITED.

-- =========================================================================
-- STEP 6  ·  View metadata
-- =========================================================================
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.VIEW_COLLABORATIONS();
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.VIEW_DATA_OFFERINGS('telco_audience_overlap');
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.VIEW_TEMPLATES('telco_audience_overlap');

-- =========================================================================
-- DONE (sisi provider)
-- Selanjutnya consumer menjalankan step yg ada di
-- 04_consumer_notebook/consumer_workflow.sql
-- =========================================================================
