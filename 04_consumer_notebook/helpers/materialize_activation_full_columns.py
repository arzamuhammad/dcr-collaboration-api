"""Materialize activation records (VARIANT) ke FLAT TABLE dengan 1000+ kolom.

Generates dan execute CREATE OR REPLACE TABLE AS SELECT dengan cast kolom
per attribute dari VARIANT payload.

Usage:
  SNOWFLAKE_CONNECTION_NAME=alvin-putra-aws-jkt \
    /tmp/sfenv/bin/python materialize_activation_full_columns.py
"""
import os
import snowflake.connector

SHARE_DB     = "SFDCR_TELCO_AUDIENCE_OVERLAP"
SEGMENT_NAME = "telco_highvalue_fullcolumns"
TARGET_TABLE = "DCR_CONSUMER_1M.DATA.ACTIVATION_TELCO_FULLCOLUMNS_FLAT"

# Tipe default per-kolom (sesuaikan kalau perlu).
# Mayoritas cast ke STRING aman dulu; tipe spesifik untuk yang sudah kita tahu.
TYPE_OVERRIDES = {
    "AGE": "NUMBER", "MONTHLY_ARPU": "FLOAT", "TENURE_MONTHS": "NUMBER",
    "DEVICE_RAM_GB": "NUMBER", "CHURN_SCORE": "FLOAT", "CLV_SCORE": "FLOAT",
    "NBA_SCORE": "FLOAT", "CREDIT_SCORE": "FLOAT", "ENGAGEMENT_SCORE": "FLOAT",
    "IS_HIGH_VALUE": "BOOLEAN", "IS_ROAMER": "BOOLEAN", "IS_FAMILY_PLAN": "BOOLEAN",
    "IS_5G_CAPABLE": "BOOLEAN",
    "OPT_IN_SMS": "BOOLEAN", "OPT_IN_EMAIL": "BOOLEAN", "OPT_IN_PUSH": "BOOLEAN",
    "FAMILY_SIZE": "NUMBER",
    "DATE_PARTITION": "NUMBER(8,0)",
    "PROPENSITY": "FLOAT",
}

conn = snowflake.connector.connect(
    connection_name=os.getenv("SNOWFLAKE_CONNECTION_NAME") or "alvin-putra-aws-jkt"
)
cur = conn.cursor()

# Get column list from the activated segment
cur.execute(f"""
SELECT DISTINCT k.VALUE::STRING AS KEY
FROM {SHARE_DB}.ACTIVATION.SEGMENT_RECORDS sr,
     LATERAL FLATTEN(INPUT => OBJECT_KEYS(sr.RECORDS:ID)) k
WHERE sr.SEGMENT_NAME = '{SEGMENT_NAME}'
ORDER BY 1
""")
all_keys = [r[0] for r in cur.fetchall()]
print(f"Total keys per record: {len(all_keys)}")

def detect_type(key_name):
    # join_clause is metadata; keep as string
    if key_name == "join_clause":
        return "STRING"
    # strip p1./c1. prefix for override lookup
    plain = key_name.split(".", 1)[-1]
    return TYPE_OVERRIDES.get(plain, "STRING")

# Build SELECT projection
def safe_col_alias(key):
    # Convert 'c1.CUSTOMER_TIER' -> 'C1_CUSTOMER_TIER'
    return key.replace(".", "_").upper()

projections = []
for k in all_keys:
    t = detect_type(k)
    alias = safe_col_alias(k)
    projections.append(f'    RECORDS:ID:"{k}"::{t:<11} AS {alias}')

proj_sql = ",\n".join(projections)

CTAS = f"""CREATE OR REPLACE TABLE {TARGET_TABLE} AS
SELECT
{proj_sql},
    BATCH_ID,
    SEGMENT_NAME,
    UPDATED_ON
FROM (
    SELECT DISTINCT RECORDS, BATCH_ID, SEGMENT_NAME, UPDATED_ON
    FROM {SHARE_DB}.ACTIVATION.SEGMENT_RECORDS
    WHERE SEGMENT_NAME = '{SEGMENT_NAME}'
)
"""

print(f"CTAS SQL size: {len(CTAS):,} bytes")
print(f"Projections: {len(projections)}")
print(f"\nFirst 5 projections:")
for p in projections[:5]: print(" ", p)
print(f"...and {len(projections)-5} more.\n")

cur.execute("USE WAREHOUSE GEN2_XLARGE")
cur.execute("ALTER WAREHOUSE GEN2_XLARGE RESUME IF SUSPENDED")
print(">>> Executing CTAS...")
cur.execute(CTAS)
r = cur.fetchone()
print(f"Result: {r}")

cur.execute(f"SELECT COUNT(*) FROM {TARGET_TABLE}")
print(f"Rows in flat table: {cur.fetchone()[0]:,}")

cur.execute(f"""
SELECT COUNT(*) AS N
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_CATALOG='{TARGET_TABLE.split('.')[0]}'
  AND TABLE_SCHEMA ='{TARGET_TABLE.split('.')[1]}'
  AND TABLE_NAME   ='{TARGET_TABLE.split('.')[2]}'
""")
print(f"Columns in flat table: {cur.fetchone()[0]:,}")

cur.close(); conn.close()
print(f"\nDONE. Flat table: {TARGET_TABLE}")
