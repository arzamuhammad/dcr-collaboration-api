"""Run DCR activation dengan SEMUA kolom provider (1000) + semua kolom consumer
yang activation_allowed=true. Build spec dinamis (spec YAML > 256 byte limit
session variable, jadi harus di-build dari Python dan dikirim sebagai arg).

Usage:
  SNOWFLAKE_CONNECTION_NAME=alvin-putra-aws-jkt \
    /tmp/sfenv/bin/python run_activation_full_columns.py
"""
import os
import snowflake.connector

COLLAB      = "telco_audience_overlap"
PROVIDER_OFF = "telco_c360_offering_v1_0"
CONSUMER_OFF = "consumer_marketing_audience_v1_0"
SHARE_DB    = "SFDCR_TELCO_AUDIENCE_OVERLAP"

# Kolom yang TIDAK di-activate dari provider (biasanya join key / PII identifier
# yang sudah di-expose via alias + tidak perlu dibawa as-is).
SKIP_PROVIDER_COLS = {"HASHED_MSISDN", "HASHED_PHONE_SHA256"}
# Consumer: semua kolom kecuali join key identical
SKIP_CONSUMER_COLS = {"HASHED_MSISDN", "HASHED_PHONE_SHA256"}

conn = snowflake.connector.connect(
    connection_name=os.getenv("SNOWFLAKE_CONNECTION_NAME") or "alvin-putra-aws-jkt"
)
cur  = conn.cursor()

# -- 1. Ambil daftar kolom provider yang allowed untuk activation (dari policy view)
cur.execute(f"""
SELECT DISTINCT COLUMN_NAME
FROM {SHARE_DB}.CLEANROOM.POLICY_COLUMNS_V
WHERE ANALYSIS_NAME = 'standard_audience_overlap_activation_v0'
  AND TABLE_NAME LIKE '%C360_TELCO%'
ORDER BY COLUMN_NAME
""")
provider_cols = [r[0] for r in cur.fetchall() if r[0] not in SKIP_PROVIDER_COLS]
print(f"Provider activation-allowed columns: {len(provider_cols)}")

# -- 2. Ambil daftar kolom consumer (dari local offering definition)
cur.execute("""
SELECT COLUMN_NAME
FROM DCR_CONSUMER_1M.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA='DATA' AND TABLE_NAME='MARKETING_AUDIENCE_DCR_DEMO'
ORDER BY ORDINAL_POSITION
""")
consumer_cols = [r[0] for r in cur.fetchall() if r[0] not in SKIP_CONSUMER_COLS]
print(f"Consumer columns: {len(consumer_cols)}")

# -- 3. Build activation_column list — gabungan c1.* + p1.*
activation_lines = []
for c in consumer_cols:
    activation_lines.append(f'      - "c1.{c}"')
for p in provider_cols:
    activation_lines.append(f'      - "p1.{p}"')
activation_block = "\n".join(activation_lines)

print(f"Total activation_column entries: {len(activation_lines)}")

# -- 4. Build full YAML spec
SPEC = f"""api_version: "2.0.0"
spec_type: "analysis"
name: "activate_overlap_fullcolumns"
description: Export matched audiens dengan SEMUA kolom provider + consumer (1005+ kolom).
template: "standard_audience_overlap_activation_v0"

template_configuration:
  view_mappings:
    source_tables:
      - "PROVIDER.{PROVIDER_OFF}.c360"
  local_view_mappings:
    my_tables:
      - "LOCAL.{CONSUMER_OFF}.audience"

  arguments:
    join_clauses:
      - "p1.HASHED_PHONE_SHA256 = c1.HASHED_PHONE_SHA256"
    activation_column:
{activation_block}
    where_clause: ""

  activation:
    snowflake_collaborator: "CONSUMER"
    segment_name: "telco_highvalue_fullcolumns"
"""

print(f"Spec size: {len(SPEC):,} bytes")

# -- 5. Run it
print("\n>>> CALL COLLABORATION.RUN(...) ...")
cur.execute("USE WAREHOUSE GEN2_XLARGE")
cur.execute("ALTER WAREHOUSE GEN2_XLARGE RESUME IF SUSPENDED")
cur.execute("CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.RUN(%s, %s)", (COLLAB, SPEC))
print("Result:")
for r in cur.fetchall():
    print(" ", r)

# -- 6. Verify
cur.execute(f"""
SELECT COUNT(*) AS ROWCNT
FROM {SHARE_DB}.ACTIVATION.SEGMENT_RECORDS
WHERE SEGMENT_NAME = 'telco_highvalue_fullcolumns'
""")
print(f"\nActivated rows (segment=telco_highvalue_fullcolumns): {cur.fetchone()[0]:,}")

cur.execute(f"""
SELECT ARRAY_SIZE(OBJECT_KEYS(RECORDS:ID)) AS COLCNT
FROM {SHARE_DB}.ACTIVATION.SEGMENT_RECORDS
WHERE SEGMENT_NAME = 'telco_highvalue_fullcolumns' LIMIT 1
""")
print(f"Columns per record: {cur.fetchone()[0]}")

cur.close(); conn.close()
print("\nDONE.")
