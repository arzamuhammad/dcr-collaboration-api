# DCR Audience Overlap via Data Collaboration API

End-to-end demo: **Provider (telco) <-> Consumer (marketing)** menggunakan
Snowflake DCR Collaboration API v2 — bukan Native App lama. Gunakan built-in
templates `standard_audience_overlap_v0` dan
`standard_audience_overlap_activation_v0`.

**Skenario data historis**: Provider me-refresh C360 mingguan; data 2 bulan =
8 weekly snapshots. Join keys composite: `HASHED_MSISDN` + `DATE_PARTITION`.

## Struktur folder

```
01_provider_data/      Generator 1.2B rows (150M × 8 partitions) × 1001 cols
02_consumer_data/      Generator 8M rows   (1M   × 8 partitions) × 7 cols  (script only)
03_provider_notebook/  SQL step-by-step sisi provider
04_consumer_notebook/  SQL step-by-step sisi consumer
```

## Urutan eksekusi

| # | Langkah | File | Dijalankan di |
|---|---------|------|---------------|
| 1 | Populate data provider | `01_provider_data/generate_provider_data.py` | Provider account |
| 2 | Populate data consumer | `02_consumer_data/generate_consumer_data.sql` | Consumer account |
| 3 | Provider setup DCR + create collaboration | `03_provider_notebook/provider_workflow.sql` | Provider account |
| 4 | Consumer join + run analysis + activation | `04_consumer_notebook/consumer_workflow.sql` | Consumer account |

## Key design

- **Composite join keys**: `HASHED_MSISDN` + `DATE_PARTITION`. Match terjadi
  per snapshot mingguan sehingga analisa temporal-aware.
  - `HASHED_MSISDN = SHA2('628' || LPAD(seed,10,'0'), 256)` — stabil antar partisi
  - `DATE_PARTITION` NUMBER(8,0) YYYYMMDD — 8 nilai: 20260302, 20260309,
    20260316, 20260323, 20260330, 20260406, 20260413, 20260420

- **Overlap control**:
  - Provider seed per partisi: `0 .. 149,999,999` (150M/partisi)
  - Consumer seed per partisi: `0 .. 699,999` (700k overlap) + `150M .. 150M+299,999` (300k non-overlap)
  - Diharapkan ~700k overlap per partisi.

- **Clustering**:
  - Provider `C360_TELCO` `CLUSTER BY (DATE_PARTITION)` — scan satu partisi cepat.
  - Consumer `MARKETING_AUDIENCE_DCR_DEMO` `CLUSTER BY (DATE_PARTITION)` — join efisien.

- **Privacy policies** pada data offering provider:
  - `HASHED_MSISDN`  -> `join_standard` (`hashed_phone_sha256`), `activation_allowed: false`
  - `DATE_PARTITION` -> `join_standard` (`dimension`), `activation_allowed: false`
  - 999 kolom lain  -> `passthrough`, `activation_allowed: true` (termasuk `HASHED_EMAIL`)

- **Activation destination**: `CONSUMER` (dirinya sendiri) → hasil activation
  muncul sebagai share di akun consumer.

## Catatan penting

1. **Replace placeholder**:
   - `SFSEAPAC.ARDIYANMUHAMMAD` -> provider account saat ini
   - `SFSEAPAC.CONSUMER_ACCOUNT` -> consumer account locator
2. **Warehouse**:
   - Generate provider data: `GEN2_2XLARGE` (suspend setelah selesai).
   - DCR operations: `GEN2_SMALL`.
3. **Urutan status JOIN**:
   - Owner (provider) bisa JOIN tanpa REVIEW.
   - Consumer WAJIB REVIEW sebelum JOIN.
4. **Partition filter**: Analysis & activation di consumer_workflow menyertakan
   `DATE_PARTITION = 20260420` (partisi terbaru). Ganti ke partisi lain
   atau hapus filter + group_by `DATE_PARTITION` untuk membandingkan antar snapshot.
5. **TEMPLATE_VIEW_NAME** pada STEP 7-8 di sisi consumer bisa berubah tergantung
   DCR version. Selalu cek dulu via `VIEW_DATA_OFFERINGS`.

## Tabel yg dibuat

### Di provider (DCR_POC_1M.PROVIDER_DATA)
- `C360_TELCO`  1,200,000,000 rows × 1001 cols  — 8 partisi × 150M rows, CLUSTER BY DATE_PARTITION

### Di consumer (DCR_CONSUMER_1M.DATA)
- `MARKETING_AUDIENCE_DCR_DEMO`  8,000,000 rows × 7 cols — 8 partisi × 1M rows (700k overlap + 300k non-overlap), CLUSTER BY DATE_PARTITION
- `ACTIVATION_TELCO_HIGHVALUE`   materialized hasil activation (opsional)
