# DCR Audience Overlap via Data Collaboration API

End-to-end recipe: **Provider (telco) ⇄ Consumer (marketing)** menggunakan
Snowflake **DCR Collaboration API v2** — bukan Native App lama. Memakai built-in
templates `standard_audience_overlap_v0` dan `standard_audience_overlap_activation_v0`.

## Struktur

```
03_provider_notebook/provider_workflow.sql   SQL step-by-step sisi PROVIDER
04_consumer_notebook/consumer_workflow.sql   SQL step-by-step sisi CONSUMER
```

## Urutan eksekusi

| # | Langkah | File | Dijalankan di |
|---|---------|------|---------------|
| 1 | Provider setup DCR + create collaboration | `03_provider_notebook/provider_workflow.sql` | Provider account |
| 2 | Consumer review + join + run analysis + activation | `04_consumer_notebook/consumer_workflow.sql` | Consumer account |

## Prerequisite

- Dua Snowflake account (provider + consumer) di region yang sama.
- DCR terinstall di keduanya: `SHOW DATABASES LIKE 'SAMOOHA_BY_SNOWFLAKE_LOCAL_DB%';`
- `SAMOOHA_APP_ROLE` tersedia (ACCOUNTADMIN bisa pakai juga).
- Tabel sumber sudah ter-populate di masing-masing account. Contoh skema yang dipakai:
  - Provider: `DCR_POC_1M.PROVIDER_DATA.C360_TELCO` (historical C360, 1.2B rows × 1001 cols, `CLUSTER BY (DATE_PARTITION)`)
  - Consumer: `DCR_CONSUMER_1M.DATA.MARKETING_AUDIENCE_DCR_DEMO` (8M rows × 7 cols, `CLUSTER BY (DATE_PARTITION)`)

## Key design

- **Join key**: `HASHED_MSISDN` (SHA-256).
  - Di data offering provider didaftarkan sebagai `join_standard` dengan `column_type: hashed_phone_sha256`.
  - Di shared template view kolom ini ter-expose sebagai `HASHED_PHONE_SHA256` — gunakan alias ini di `join_clauses`.

- **Partition matching**: `DATE_PARTITION` (NUMBER YYYYMMDD) didaftarkan `passthrough`.
  - `column_type: dimension` TIDAK valid; hanya PII types (`hashed_phone_sha256`, `hashed_email_sha256`, dst.) yang boleh jadi `join_standard`.
  - Match antar-partisi diterapkan via `my_where_clause` + `source_where_clause` di runtime RUN, bukan di `join_clauses`.

- **Overlap control (design target, terverifikasi)**:
  - Provider seed: `0 .. 149,999,999` per partisi.
  - Consumer seed: `0 .. 699,999` (700k overlap) + `150,000,000 .. 150,299,999` (300k non-overlap).
  - Hasil: **700k OVERLAP / 300k NON-OVERLAP** per partisi.

- **Activation destination**: `CONSUMER` (self) — hasil activation muncul sebagai share di akun consumer.

## Catatan penting (battle-tested fixes)

1. **YAML spec > 256 bytes** → tidak bisa pakai session variable `SET`. Build YAML di client (Python) lalu pass sebagai argument ke `REGISTER_DATA_OFFERING(<spec>)`.
2. **`column_type` whitelist ketat** → hanya PII types valid. Untuk date/partition/dimension pakai `passthrough`.
3. **Shared view renames join columns** → `HASHED_MSISDN` → `HASHED_PHONE_SHA256` di template view.
4. **Templates bawaan tidak auto-registered** → wajib `CALL REGISTRY.REGISTER_STANDARD_DCR_TEMPLATES()` di **kedua** account sebelum INITIALIZE / RUN.
5. **`GRANT REFERENCE_USAGE ... TO SHARE SAMOOHA_BY_SNOWFLAKE_APP_SHARE`** adalah pattern legacy v1. **Skip**.
6. **`source_tables` / `my_tables` PLURAL arrays** di RUN spec (string singular fails validation).
7. **PAT session restricted `USE ROLE`** → connect as ACCOUNTADMIN yang sudah inherit role.
8. **Activation output VARIANT format**:
   ```sql
   RECORDS:ID:"c1.<column>"::<TYPE>
   RECORDS:ID:"p1.DATE_PARTITION"::NUMBER
   RECORDS:ID:"join_clause"::STRING
   ```

## Placeholder yang harus di-replace

Sebelum run, ubah nilai berikut di kedua SQL file:
- `SFSEAPAC.ARDIYANMUHAMMAD` → account identifier provider Anda
- `SFSEAPAC.ALVIN_JKT` → account identifier consumer Anda
- `<CONSUMER_USER>`, `<DATE_PARTITION>` sesuai kebutuhan

## Alur state INITIALIZE

```
INITIALIZE (sync 30s) → CREATING → CREATED (~9 min) → INSTALLING (~9.2 min) → JOINED (~12 min)
```
Pantau dengan `COLLABORATION.GET_STATUS('<collab_name>')`. `VIEW_DATA_OFFERINGS` baru tersedia setelah status `JOINED`.

## Referensi

- [Snowflake DCR Collaboration API v2](https://docs.snowflake.com/en/user-guide/cleanrooms/v2/about)
- [Spec reference](https://docs.snowflake.com/en/user-guide/cleanrooms/v2/spec-reference)
- [API reference](https://docs.snowflake.com/en/user-guide/cleanrooms/v2/v2-api-reference)
