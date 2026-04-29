"""
Generator untuk data provider Telco C360 (HISTORICAL / PARTITIONED).

Tabel:
  DCR_POC_1M.PROVIDER_DATA.C360_TELCO
    -> 150,000,000 rows per partition x 8 weekly partitions = 1,200,000,000 rows
    -> 1001 columns (1000 feature/identifier cols + DATE_PARTITION)
    -> CLUSTER BY (DATE_PARTITION)

Join keys (composite):
  - HASHED_MSISDN   : SHA-256 dari MSISDN (stabil antar partisi utk customer yang sama)
  - DATE_PARTITION  : NUMBER(8,0) dalam format YYYYMMDD

Partisi (8 minggu, Senin mingguan):
  20260302, 20260309, 20260316, 20260323,
  20260330, 20260406, 20260413, 20260420

Catatan eksekusi:
  - Pakai warehouse GEN2_2XLARGE (di-set otomatis)
  - 8 INSERT terpisah agar memory-friendly; tiap INSERT ~150M rows
  - HASHED_MSISDN untuk baris ke-i deterministik (SEQ8()), sehingga consumer
    dapat membangun data overlap / non-overlap terkontrol dan berjodoh per partisi.
"""

import os
import time
import snowflake.connector

CONN_NAME   = os.getenv("SNOWFLAKE_CONNECTION_NAME") or "ardiyanmuhammad-aws-jkt"
WAREHOUSE   = "GEN2_2XLARGE"
DATABASE    = "DCR_POC_1M"
SCHEMA      = "PROVIDER_DATA"

MAIN_TABLE  = "C360_TELCO"
BACKUP_TABLE = "C360_TELCO_BACKUP"  # old table to drop

ROWS_PER_PARTITION = 150_000_000
MAIN_COLS          = 1000  # tidak termasuk DATE_PARTITION

# 8 weekly Mondays covering ~2 months (YYYYMMDD as int)
DATE_PARTITIONS = [
    20260302, 20260309, 20260316, 20260323,
    20260330, 20260406, 20260413, 20260420,
]

# -------------------------------------------------------------------------
# Named telco columns (identifier + demographics + plan + device + usage + scores)
# 3 identifier + 47 telco fields = 50 named cols
# -------------------------------------------------------------------------
NAMED_COLS = [
    ("CUSTOMER_ID",          "STRING",   "'CUST_' || LPAD(SEQ8()::STRING, 12, '0')"),
    ("HASHED_MSISDN",        "STRING",   "SHA2('628' || LPAD(SEQ8()::STRING, 10, '0'), 256)"),
    ("HASHED_EMAIL",         "STRING",   "SHA2('user' || SEQ8()::STRING || '@telco.co.id', 256)"),
    ("AGE",                  "NUMBER",   "18 + UNIFORM(0, 60, RANDOM())"),
    ("GENDER",               "STRING",   "DECODE(UNIFORM(0,1,RANDOM()),0,'M','F')"),
    ("PROVINCE",             "STRING",   "ARRAY_CONSTRUCT('DKI Jakarta','Jawa Barat','Jawa Timur','Jawa Tengah','Banten','Sumatera Utara','Sumatera Selatan','Sulawesi Selatan','Bali','Kalimantan Timur')[UNIFORM(0,9,RANDOM())]::STRING"),
    ("CITY",                 "STRING",   "ARRAY_CONSTRUCT('Jakarta','Bandung','Surabaya','Medan','Semarang','Makassar','Palembang','Denpasar','Balikpapan','Yogyakarta')[UNIFORM(0,9,RANDOM())]::STRING"),
    ("INCOME_BRACKET",       "STRING",   "ARRAY_CONSTRUCT('<3M','3-5M','5-10M','10-20M','>20M')[UNIFORM(0,4,RANDOM())]::STRING"),
    ("OCCUPATION",           "STRING",   "ARRAY_CONSTRUCT('Student','Employee','Self-Employed','Professional','Entrepreneur','Retired')[UNIFORM(0,5,RANDOM())]::STRING"),
    ("EDUCATION",            "STRING",   "ARRAY_CONSTRUCT('SMP','SMA','D3','S1','S2','S3')[UNIFORM(0,5,RANDOM())]::STRING"),
    ("MARITAL_STATUS",       "STRING",   "ARRAY_CONSTRUCT('Single','Married','Divorced')[UNIFORM(0,2,RANDOM())]::STRING"),
    ("FAMILY_SIZE",          "NUMBER",   "1 + UNIFORM(0, 7, RANDOM())"),
    ("PLAN_TYPE",            "STRING",   "ARRAY_CONSTRUCT('PREPAID','POSTPAID')[UNIFORM(0,1,RANDOM())]::STRING"),
    ("PLAN_NAME",            "STRING",   "ARRAY_CONSTRUCT('Basic','Silver','Gold','Platinum','Unlimited')[UNIFORM(0,4,RANDOM())]::STRING"),
    ("MONTHLY_ARPU",         "FLOAT",    "ROUND(UNIFORM(20000, 800000, RANDOM())::FLOAT, 2)"),
    ("CONTRACT_START_DATE",  "DATE",     "DATEADD('day', -UNIFORM(0, 1460, RANDOM()), CURRENT_DATE())"),
    ("CONTRACT_END_DATE",    "DATE",     "DATEADD('day', UNIFORM(0, 730, RANDOM()), CURRENT_DATE())"),
    ("PAYMENT_METHOD",       "STRING",   "ARRAY_CONSTRUCT('Autodebit','Ewallet','Bank Transfer','Credit Card','Retail')[UNIFORM(0,4,RANDOM())]::STRING"),
    ("BILLING_CYCLE",        "STRING",   "ARRAY_CONSTRUCT('Monthly','Quarterly','Annual')[UNIFORM(0,2,RANDOM())]::STRING"),
    ("LOYALTY_TIER",         "STRING",   "ARRAY_CONSTRUCT('Bronze','Silver','Gold','Platinum','Diamond')[UNIFORM(0,4,RANDOM())]::STRING"),
    ("TENURE_MONTHS",        "NUMBER",   "UNIFORM(1, 120, RANDOM())"),
    ("DEVICE_BRAND",         "STRING",   "ARRAY_CONSTRUCT('Samsung','Apple','Xiaomi','Oppo','Vivo','Realme','Huawei','Infinix')[UNIFORM(0,7,RANDOM())]::STRING"),
    ("DEVICE_MODEL",         "STRING",   "'Model-' || UNIFORM(1,500,RANDOM())::STRING"),
    ("DEVICE_OS",            "STRING",   "DECODE(UNIFORM(0,1,RANDOM()),0,'Android','iOS')"),
    ("OS_VERSION",           "STRING",   "UNIFORM(8,17,RANDOM())::STRING || '.' || UNIFORM(0,9,RANDOM())::STRING"),
    ("DEVICE_RAM_GB",        "NUMBER",   "ARRAY_CONSTRUCT(3,4,6,8,12,16)[UNIFORM(0,5,RANDOM())]::NUMBER"),
    ("IS_5G_CAPABLE",        "BOOLEAN",  "UNIFORM(0,1,RANDOM())=1"),
    ("SIM_TYPE",             "STRING",   "ARRAY_CONSTRUCT('Physical','eSIM','Dual')[UNIFORM(0,2,RANDOM())]::STRING"),
    ("VOICE_MIN_M1",         "NUMBER",   "UNIFORM(0, 2000, RANDOM())"),
    ("VOICE_MIN_M2",         "NUMBER",   "UNIFORM(0, 2000, RANDOM())"),
    ("VOICE_MIN_M3",         "NUMBER",   "UNIFORM(0, 2000, RANDOM())"),
    ("DATA_MB_M1",           "NUMBER",   "UNIFORM(0, 100000, RANDOM())"),
    ("DATA_MB_M2",           "NUMBER",   "UNIFORM(0, 100000, RANDOM())"),
    ("DATA_MB_M3",           "NUMBER",   "UNIFORM(0, 100000, RANDOM())"),
    ("SMS_M1",               "NUMBER",   "UNIFORM(0, 500, RANDOM())"),
    ("SMS_M2",               "NUMBER",   "UNIFORM(0, 500, RANDOM())"),
    ("SMS_M3",               "NUMBER",   "UNIFORM(0, 500, RANDOM())"),
    ("ROAMING_MB_M1",        "NUMBER",   "UNIFORM(0, 5000, RANDOM())"),
    ("CHURN_SCORE",          "FLOAT",    "ROUND(UNIFORM(0, 100, RANDOM())/100.0, 4)"),
    ("CLV_SCORE",            "FLOAT",    "ROUND(UNIFORM(0, 1000, RANDOM())/10.0, 2)"),
    ("NBA_SCORE",            "FLOAT",    "ROUND(UNIFORM(0, 100, RANDOM())/100.0, 4)"),
    ("CREDIT_SCORE",         "NUMBER",   "UNIFORM(300, 850, RANDOM())"),
    ("ENGAGEMENT_SCORE",     "FLOAT",    "ROUND(UNIFORM(0, 100, RANDOM())/100.0, 4)"),
    ("IS_HIGH_VALUE",        "BOOLEAN",  "UNIFORM(0,1,RANDOM())=1"),
    ("IS_ROAMER",            "BOOLEAN",  "UNIFORM(0,9,RANDOM())=0"),
    ("IS_FAMILY_PLAN",       "BOOLEAN",  "UNIFORM(0,1,RANDOM())=1"),
    ("OPT_IN_SMS",           "BOOLEAN",  "UNIFORM(0,1,RANDOM())=1"),
    ("OPT_IN_EMAIL",         "BOOLEAN",  "UNIFORM(0,1,RANDOM())=1"),
    ("OPT_IN_PUSH",          "BOOLEAN",  "UNIFORM(0,1,RANDOM())=1"),
    ("LAST_ACTIVITY_DATE",   "DATE",     "DATEADD('day', -UNIFORM(0, 90, RANDOM()), CURRENT_DATE())"),
]

assert len(NAMED_COLS) == 50, f"Expected 50 named cols, got {len(NAMED_COLS)}"


def build_feature_cols(total_cols: int):
    n_features = total_cols - len(NAMED_COLS)
    cols = []
    for i in range(1, n_features + 1):
        if i % 5 == 0:
            expr = "ROUND(UNIFORM(0, 10000, RANDOM())/100.0, 2)"
            typ  = "FLOAT"
        elif i % 3 == 0:
            expr = "UNIFORM(0, 1000, RANDOM())"
            typ  = "NUMBER"
        elif i % 7 == 0:
            expr = "UNIFORM(0,1,RANDOM())=1"
            typ  = "BOOLEAN"
        else:
            expr = "ROUND(UNIFORM(0, 1000, RANDOM())/10.0, 2)"
            typ  = "FLOAT"
        cols.append((f"FEAT_{i:04d}", typ, expr))
    return cols


def build_ddl(fqname: str, total_cols: int) -> str:
    """Create table with DATE_PARTITION first + cluster key."""
    cols = NAMED_COLS + build_feature_cols(total_cols)
    ddl_cols = ",\n  ".join(f"{name} {typ}" for name, typ, _ in cols)
    ddl = (
        f"CREATE OR REPLACE TABLE {fqname} (\n"
        f"  DATE_PARTITION NUMBER(8,0),\n"
        f"  {ddl_cols}\n"
        f")\n"
        f"CLUSTER BY (DATE_PARTITION);"
    )
    return ddl


def build_insert(fqname: str, total_cols: int, date_partition: int, rowcount: int) -> str:
    cols = NAMED_COLS + build_feature_cols(total_cols)
    select_exprs = ",\n  ".join(f"{expr} AS {name}" for name, _, expr in cols)
    col_names = ",".join(["DATE_PARTITION"] + [name for name, _, _ in cols])
    return (
        f"INSERT INTO {fqname} ({col_names})\n"
        f"SELECT\n"
        f"  {date_partition} AS DATE_PARTITION,\n"
        f"  {select_exprs}\n"
        f"FROM TABLE(GENERATOR(ROWCOUNT => {rowcount}));"
    )


def ensure_warehouse(cur):
    cur.execute(
        f"CREATE WAREHOUSE IF NOT EXISTS {WAREHOUSE} "
        f"WAREHOUSE_SIZE='2X-LARGE' WAREHOUSE_TYPE='SNOWPARK-OPTIMIZED' "
        f"AUTO_SUSPEND=60 INITIALLY_SUSPENDED=FALSE"
    )
    cur.execute(f"USE WAREHOUSE {WAREHOUSE}")


def main():
    conn = snowflake.connector.connect(connection_name=CONN_NAME)
    cur  = conn.cursor()
    try:
        try:
            cur.execute(f"USE WAREHOUSE {WAREHOUSE}")
            cur.execute(f"ALTER WAREHOUSE {WAREHOUSE} RESUME IF SUSPENDED")
        except Exception:
            ensure_warehouse(cur)

        cur.execute(f"CREATE DATABASE IF NOT EXISTS {DATABASE}")
        cur.execute(f"CREATE SCHEMA IF NOT EXISTS {DATABASE}.{SCHEMA}")
        cur.execute(f"USE SCHEMA {DATABASE}.{SCHEMA}")

        main_fq = f"{DATABASE}.{SCHEMA}.{MAIN_TABLE}"
        bak_fq  = f"{DATABASE}.{SCHEMA}.{BACKUP_TABLE}"

        # ---- Drop old tables ----
        print(f"[DROP] {main_fq}")
        cur.execute(f"DROP TABLE IF EXISTS {main_fq}")
        print(f"[DROP] {bak_fq}")
        cur.execute(f"DROP TABLE IF EXISTS {bak_fq}")

        # ---- Create new historical table ----
        print(f"[CREATE] {main_fq} ({MAIN_COLS+1} cols, CLUSTER BY DATE_PARTITION)")
        cur.execute(build_ddl(main_fq, MAIN_COLS))

        # ---- Populate 8 partitions ----
        for i, dp in enumerate(DATE_PARTITIONS, start=1):
            print(f"[INSERT {i}/{len(DATE_PARTITIONS)}] DATE_PARTITION={dp} rows={ROWS_PER_PARTITION:,}")
            t0 = time.time()
            cur.execute(build_insert(main_fq, MAIN_COLS, dp, ROWS_PER_PARTITION))
            print(f"    done in {time.time()-t0:.1f}s")

        # ---- Summary ----
        cur.execute(f"SELECT COUNT(*) FROM {main_fq}")
        print(f"{main_fq} total row_count = {cur.fetchone()[0]:,}")
        cur.execute(
            f"SELECT DATE_PARTITION, COUNT(*) FROM {main_fq} "
            f"GROUP BY 1 ORDER BY 1"
        )
        for row in cur.fetchall():
            print(f"  DATE_PARTITION={row[0]}  rows={row[1]:,}")

    finally:
        cur.close()
        conn.close()


if __name__ == "__main__":
    main()
