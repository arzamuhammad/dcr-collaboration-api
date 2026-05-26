# Snowflake Data Clean Room — Collaboration API v2 Playbook

> End-to-end recipe to build a working DCR (Data Clean Room) between two Snowflake accounts using **Collaboration API v2** — the modern, symmetric, declarative successor to the legacy DCR Native App.
>
> Battle-tested on a 1.2B-row × 8M-row provider/consumer dataset, with verified 70% overlap rate, full performance benchmarks, and 8 documented gotchas you'd otherwise hit production-blind.

---

## Who This Is For

You should read this if you want to:

- **Build or debug** an end-to-end audience overlap workflow with composite / partitioned join keys
- **Share 100s–1000s of passthrough columns** from provider to consumer
- Run `standard_audience_overlap_v0` / `standard_audience_overlap_activation_v0`
- Migrate from DCR Native App (v1) to Collaboration API (v2)
- Encounter cryptic errors like:
  - `Assignment to '...' not done because value exceeds size limit for variables`
  - `'dimension' is not one of [...]` on column_type validation
  - `Unauthorized columns: p1.<col>` in analysis
  - `Templates 'standard_audience_overlap_v0' do not exist`
  - `argument 1 to function LISTAGG needs to be constant`
  - `Share 'SAMOOHA_BY_SNOWFLAKE_APP_SHARE' does not exist`

---

## High-Level Flow

```
┌──────────────────┐                                   ┌──────────────────┐
│  PROVIDER        │                                   │  CONSUMER        │
├──────────────────┤                                   ├──────────────────┤
│ 1. Grants        │                                   │                  │
│ 2. Register      │                                   │                  │
│    standard      │                                   │                  │
│    templates     │                                   │                  │
│ 3. Register      │                                   │                  │
│    data_offering │                                   │                  │
│ 4. INITIALIZE    │ ──── invitation ────────────────▶ │ 5. REVIEW        │
│    collaboration │                                   │ 6. JOIN          │
│ 5. Owner auto-   │                                   │ 7. Grants        │
│    join          │                                   │ 8. Register      │
│                  │                                   │    standard      │
│                  │                                   │    templates     │
│                  │                                   │ 9. Register      │
│                  │                                   │    local offering│
│                  │                                   │10. LINK local    │
│                  │                                   │11. VIEW to get   │
│                  │                                   │    TEMPLATE_VIEW │
│                  │                                   │    _NAME         │
│                  │                                   │12. RUN analysis  │
│                  │ ◀─ query view share ──────────── │    → overlap cnt │
│                  │                                   │13. RUN activation│
│                  │ ◀─ build segment results ─────── │    → share lands │
│                  │                                   │    in consumer   │
│                  │                                   │14. Flatten to    │
│                  │                                   │    native table  │
└──────────────────┘                                   └──────────────────┘
```

---

## Prerequisites (run in BOTH accounts)

```sql
SHOW DATABASES LIKE 'SAMOOHA_BY_SNOWFLAKE_LOCAL_DB%';
```

If not found → DCR not installed. Ask admin to install **"Snowflake Data Clean Room"** native app from the Snowflake Marketplace (free).

Verify account identity:

```sql
SELECT CURRENT_ORGANIZATION_NAME() || '.' || CURRENT_ACCOUNT_NAME() AS ACCOUNT;
```

You will need **`ACCOUNTADMIN`** (or equivalent) on both accounts to install the native app and grant `SAMOOHA_APP_ROLE`.

---

## 8 Critical Gotchas (Learned the Hard Way)

### 1. YAML spec size limit — 256 bytes per session variable

**Session variable (`SET X = ...`) has a 256-byte hard cap.** Cannot hold a full data_offering YAML with 100+ columns.

- **Fix Option A (Python client)**: Build spec in Python and pass as argument to `REGISTER_DATA_OFFERING(<spec_string>)`.
- **Fix Option B (Snowflake Scripting)**: Local `STRING` variable inside `DECLARE...BEGIN...END` block has no 256B limit. Use `LISTAGG` to build the spec dynamically:

```sql
DECLARE
  spec STRING;
BEGIN
  SELECT 'header...' || LISTAGG('      - ' || COL_NAME, '\n')
                         WITHIN GROUP (ORDER BY ORDINAL_POSITION)
         || '\nfooter...'
    INTO :spec
  FROM INFORMATION_SCHEMA.COLUMNS WHERE ...;

  CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.RUN('<collab>', :spec);
END;
```

- **Anti-pattern**: `SET POLICIES_YAML = (SELECT LISTAGG(...))` for >256B results — fails silently or truncates.
- **LISTAGG gotcha**: `LISTAGG(..., CHR(10))` fails with *"delimiter must be constant"* — use literal `'\n'` inside a quoted string.

### 2. `column_type` whitelist is PII-only

Valid values for `join_standard.column_type`:

```
email, hashed_email_sha256, hashed_email_b64_encoded,
phone, hashed_phone_sha256, hashed_phone_b64_encoded,
device_id, hashed_device_id_sha256, hashed_device_b64_encoded,
ip_address, hashed_ip_address_sha256, hashed_ip_address_b64_encoded,
first_name, hashed_first_name_sha256, hashed_first_name_b64_encoded,
last_name, hashed_last_name_sha256, hashed_last_name_b64_encoded
```

`dimension`, `date`, `partition`, `custom` → **INVALID**.

**Fix for date/partition columns**: declare as `passthrough` with `activation_allowed: true`. Scope partition matching via `where_clause` in RUN call (NOT in `join_clauses`):

```yaml
my_where_clause:     "c1.DATE_PARTITION = 20260420"
source_where_clause: "p1.DATE_PARTITION = 20260420"
```

### 3. Shared view renames join columns to `column_type` alias

When you declare:

```yaml
HASHED_MSISDN: { category: join_standard, column_type: hashed_phone_sha256 }
```

The shared template view exposes the column as **`HASHED_PHONE_SHA256`**, NOT `HASHED_MSISDN`.

- In `join_clauses` use the alias: `p1.HASHED_PHONE_SHA256 = c1.HASHED_PHONE_SHA256`
- In `count_column` use alias without prefix: `"HASHED_PHONE_SHA256"`

Discover actual column names:

```sql
SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_CATALOG LIKE 'SFDCR_%';
```

### 4. Built-in templates NOT auto-registered

`standard_audience_overlap_v0` and `standard_audience_overlap_activation_v0` are NOT available after DCR install. Must explicitly register in **BOTH** accounts:

```sql
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.REGISTRY.REGISTER_STANDARD_DCR_TEMPLATES();
```

### 5. PAT session role restrictions

Many PAT (Programmatic Access Token) sessions restrict to a single role → `USE ROLE ...` returns `Current session is restricted. USE ROLE not allowed`.

- Workaround: ACCOUNTADMIN inherits SAMOOHA_APP_ROLE capabilities via `CURRENT_AVAILABLE_ROLES()`. DCR CALLs work as ACCOUNTADMIN.
- Still GRANT the role for auditability: `GRANT ROLE SAMOOHA_APP_ROLE TO USER <user>`.

### 6. Legacy share grant `SAMOOHA_BY_SNOWFLAKE_APP_SHARE`

`GRANT REFERENCE_USAGE ON DATABASE <db> TO SHARE SAMOOHA_BY_SNOWFLAKE_APP_SHARE` is a **v1 / Native App** pattern. The share does NOT exist in v2. **Skip it** — the CALL procedures handle sharing internally.

### 7. Parameter shape: ARRAY plural, not singular string

```yaml
# CORRECT
template_configuration:
  view_mappings:
    source_tables:    # plural, array
      - "PROVIDER.<offering_id>.<alias>"
  local_view_mappings:
    my_tables:        # plural, array
      - "LOCAL.<offering_id>.<alias>"
```

Wrong forms:
- `source_table: "..."` singular string → validation error
- Empty `my_tables: []` when there is a LOCAL offering → uses wrong aliases

### 8. Activation output format is VARIANT-nested

`RUN(activation template)` creates `<sfdcr_collab>.ACTIVATION.SEGMENT_RECORDS` with a **VARIANT `RECORDS` column** holding nested object:

```json
{ "ID": { "c1.CUSTOMER_TIER": "...", "c1.SEGMENT": "...",
          "p1.DATE_PARTITION": "20260420", "join_clause": "..." } }
```

Flatten with:

```sql
RECORDS:ID:"c1.CUSTOMER_TIER"::STRING
```

Note the literal column key includes the `c1.`/`p1.` prefix — quote it.

---

## PROVIDER Workflow

### Step P-0: Inputs to gather

- **Provider account identifier** (e.g. `ORG.ACCOUNT`)
- **Consumer account identifier**
- **Source table FQN** (e.g. `DB.SCHEMA.TABLE`)
- **Join key column** + PII type (typically `hashed_phone_sha256` or `hashed_email_sha256`)
- **Data offering name** (e.g. `c360_offering`)
- **Collaboration name** (e.g. `audience_overlap`)
- **Warehouse** for DCR operations (default `GEN2_SMALL` is fine)

### Step P-1: Grants

```sql
GRANT ROLE SAMOOHA_APP_ROLE TO USER <user>;
GRANT USAGE  ON DATABASE <db> TO ROLE SAMOOHA_APP_ROLE;
GRANT USAGE  ON SCHEMA   <db>.<schema> TO ROLE SAMOOHA_APP_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA <db>.<schema> TO ROLE SAMOOHA_APP_ROLE;
-- Do NOT grant REFERENCE_USAGE to SAMOOHA_BY_SNOWFLAKE_APP_SHARE.
```

### Step P-2: Register standard templates

```sql
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.REGISTRY.REGISTER_STANDARD_DCR_TEMPLATES();
```

### Step P-3: Register data offering (Python-built spec for >100 cols)

```python
import os, snowflake.connector

conn = snowflake.connector.connect(connection_name=os.environ["SNOWFLAKE_CONNECTION_NAME"])
cur = conn.cursor()

cur.execute("""
SELECT COLUMN_NAME FROM <DB>.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA='<SCHEMA>' AND TABLE_NAME='<TABLE>'
  AND COLUMN_NAME NOT IN ('<JOIN_KEY_COL>')
ORDER BY ORDINAL_POSITION
""")
cols = [r[0] for r in cur.fetchall()]

policies = "\n".join(
    f"      {c}: {{ category: passthrough, activation_allowed: true }}" for c in cols
)

SPEC = f"""api_version: "2.0.0"
spec_type: data_offering
name: <OFFERING_NAME>
version: "v1_0"
description: <desc>
datasets:
  - alias: <ALIAS>
    data_object_fqn: <DB>.<SCHEMA>.<TABLE>
    allowed_analyses: template_only
    object_class: custom
    schema_and_template_policies:
      <JOIN_KEY_COL>: {{ category: join_standard, column_type: hashed_phone_sha256, activation_allowed: false }}
{policies}
"""

cur.execute("CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.REGISTRY.REGISTER_DATA_OFFERING(%s)", (SPEC,))
print(cur.fetchall())
```

Verify:

```sql
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.REGISTRY.VIEW_REGISTERED_DATA_OFFERINGS();
```

### Step P-4: INITIALIZE collaboration

```sql
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.INITIALIZE($$
api_version: "2.0.0"
spec_type: collaboration
name: <COLLAB_NAME>
description: <desc>

collaborator_identifier_aliases:
  PROVIDER: <PROVIDER_ORG_ACCT>
  CONSUMER: <CONSUMER_ORG_ACCT>

owner: PROVIDER

analysis_runners:
  CONSUMER:
    data_providers:
      PROVIDER:
        data_offerings:
          - id: <OFFERING_NAME>_v1_0
    templates:
      - id: standard_audience_overlap_v0
      - id: standard_audience_overlap_activation_v0
    activation_destinations:
      snowflake_collaborators:
        - CONSUMER
$$, 'GEN2_SMALL');
```

### Step P-5: Wait for auto-join + monitor

```sql
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.GET_STATUS('<COLLAB_NAME>');
```

Expected progression: `CREATING` → `INSTALLING` → `JOINED` (typically 3–12 minutes for first-time setup; depends on inter-region latency).

If owner stuck in INSTALLING > 15 min, manually JOIN:

```sql
USE SECONDARY ROLES NONE;
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.JOIN('<COLLAB_NAME>');
USE SECONDARY ROLES ALL;
```

**STOP HERE** — switch to consumer account to proceed.

---

## CONSUMER Workflow

### Step C-0: Confirm consumer account
Verify `CURRENT_ACCOUNT()` matches the `CONSUMER` identifier from provider's INITIALIZE spec.

### Step C-1: Grants

```sql
GRANT ROLE SAMOOHA_APP_ROLE TO USER <user>;
GRANT USAGE  ON DATABASE <local_db> TO ROLE SAMOOHA_APP_ROLE;
GRANT USAGE  ON SCHEMA   <local_db>.<schema> TO ROLE SAMOOHA_APP_ROLE;
GRANT SELECT ON TABLE    <local_db>.<schema>.<local_table> TO ROLE SAMOOHA_APP_ROLE;
```

### Step C-2: Register standard templates

```sql
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.REGISTRY.REGISTER_STANDARD_DCR_TEMPLATES();
```

### Step C-3: View invitation

```sql
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.VIEW_COLLABORATIONS();
```

Look for row with `OWNER_ACCOUNT=<provider>` and `COLLABORATION_NAME=NULL` → pending invitation.

### Step C-4: REVIEW + JOIN

```sql
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.REVIEW(
  '<source_name>',          -- from SOURCE_NAME col
  '<provider_org_acct>',
  '<local_name>'            -- can be same as source_name
);

CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.JOIN('<local_name>');

-- Wait 1-2 min, then verify
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.GET_STATUS('<local_name>');
```

Expected: both PROVIDER and CONSUMER `JOINED`.

### Step C-5: Register local data offering

```sql
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.REGISTRY.REGISTER_DATA_OFFERING($$
api_version: "2.0.0"
spec_type: data_offering
name: <CONSUMER_OFFERING_NAME>
version: "v1_0"
description: <desc>
datasets:
  - alias: <ALIAS>
    data_object_fqn: <LOCAL_DB>.<SCHEMA>.<TABLE>
    allowed_analyses: template_only
    object_class: custom
    schema_and_template_policies:
      <JOIN_KEY>:       { category: join_standard, column_type: hashed_phone_sha256, activation_allowed: true }
      DATE_PARTITION:   { category: passthrough, activation_allowed: true }
      <attr1>:          { category: passthrough, activation_allowed: true }
      <attr2>:          { category: passthrough, activation_allowed: true }
$$);
```

### Step C-6: LINK local offering to collaboration

```sql
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.LINK_LOCAL_DATA_OFFERING(
  '<collab_name>',
  '<CONSUMER_OFFERING_NAME>_v1_0'
);
```

### Step C-7: Discover TEMPLATE_VIEW_NAME

```sql
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.VIEW_DATA_OFFERINGS('<collab_name>');
```

Note these column values:

| Column | Meaning |
|---|---|
| `TEMPLATE_VIEW_NAME` | Use verbatim in `source_tables` or `my_tables` |
| `TEMPLATE_JOIN_COLUMNS` | Allowed in `join_clauses` (column_type aliases) |
| `ANALYSIS_ALLOWED_COLUMNS` | Allowed in `where_clause` / `group_by` |
| `ACTIVATION_ALLOWED_COLUMNS` | Allowed in `activation_column` |
| `SHARED_BY` | Collaborator name of data owner |

### Step C-8: RUN analysis (overlap count)

```sql
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.RUN('<collab_name>', $$
api_version: "2.0.0"
spec_type: "analysis"
name: "overlap_count"
template: "standard_audience_overlap_v0"

template_configuration:
  view_mappings:
    source_tables:
      - "PROVIDER.<provider_offering>_v1_0.<alias>"
  local_view_mappings:
    my_tables:
      - "LOCAL.<consumer_offering>_v1_0.<alias>"

  arguments:
    join_clauses:
      - "p1.HASHED_PHONE_SHA256 = c1.HASHED_PHONE_SHA256"
    count_column:
      - "HASHED_PHONE_SHA256"
    my_where_clause:     "c1.DATE_PARTITION = <YYYYMMDD>"
    source_where_clause: "p1.DATE_PARTITION = <YYYYMMDD>"
    my_group_by: []
    source_group_by: []
$$);
```

Returns: `WATERFALL_LEVEL | METRIC_TYPE | COUNT_VALUE | TOTAL_COUNT | MATCH_CRITERIA`.

### Step C-9: RUN activation (build segment for export)

```sql
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.RUN('<collab_name>', $$
api_version: "2.0.0"
spec_type: "analysis"
name: "activate_segment"
template: "standard_audience_overlap_activation_v0"

template_configuration:
  view_mappings:
    source_tables:
      - "PROVIDER.<provider_offering>_v1_0.<alias>"
  local_view_mappings:
    my_tables:
      - "LOCAL.<consumer_offering>_v1_0.<alias>"

  arguments:
    join_clauses:
      - "p1.HASHED_PHONE_SHA256 = c1.HASHED_PHONE_SHA256"
    activation_column:
      - "c1.<attr1>"
      - "c1.<attr2>"
      - "p1.DATE_PARTITION"
    where_clause: "p1.DATE_PARTITION = <YYYYMMDD> AND c1.DATE_PARTITION = <YYYYMMDD>"

  activation:
    snowflake_collaborator: "CONSUMER"
    segment_name: "<segment_name>"
$$);
```

Returns `BATCH_ID` + `RESULTS_TABLE`. The share `SFDCR_<COLLAB_NAME>.ACTIVATION.SEGMENT_RECORDS` is auto-populated.

### Step C-9 ALT: Activation with 1000+ columns (dynamic spec)

When `activation_column` has many entries (>100), use Snowflake Scripting to bypass the 256B session variable limit:

```sql
USE WAREHOUSE GEN2_2XLARGE;  -- size up for wide-column activation
ALTER WAREHOUSE GEN2_2XLARGE RESUME IF SUSPENDED;

DECLARE
  consumer_lines STRING; provider_lines STRING; spec STRING; result VARIANT;
BEGIN
  SELECT LISTAGG('      - "c1.' || COLUMN_NAME || '"', '\n')
         WITHIN GROUP (ORDER BY ORDINAL_POSITION) INTO :consumer_lines
  FROM <LOCAL_DB>.INFORMATION_SCHEMA.COLUMNS
  WHERE TABLE_SCHEMA='<SCHEMA>' AND TABLE_NAME='<TABLE>'
    AND COLUMN_NAME NOT IN ('<JOIN_KEY>');

  SELECT LISTAGG('      - "p1.' || COLUMN_NAME || '"', '\n')
         WITHIN GROUP (ORDER BY COLUMN_NAME) INTO :provider_lines
  FROM (SELECT DISTINCT COLUMN_NAME
        FROM SFDCR_<COLLAB>.CLEANROOM.POLICY_COLUMNS_V
        WHERE ANALYSIS_NAME='standard_audience_overlap_activation_v0'
          AND TABLE_NAME LIKE '%<PROVIDER_TABLE>%'
          AND COLUMN_NAME NOT IN ('<JOIN_KEY>','<JOIN_KEY_ALIAS>'));

  spec := 'api_version: "2.0.0"
spec_type: "analysis"
name: "activate_fullcols"
template: "standard_audience_overlap_activation_v0"
template_configuration:
  view_mappings:
    source_tables: ["PROVIDER.<provider_offering>_v1_0.<alias>"]
  local_view_mappings:
    my_tables: ["LOCAL.<consumer_offering>_v1_0.<alias>"]
  arguments:
    join_clauses: ["p1.HASHED_PHONE_SHA256 = c1.HASHED_PHONE_SHA256"]
    activation_column:
' || :consumer_lines || '
' || :provider_lines || '
    where_clause: "p1.DATE_PARTITION = <YYYYMMDD> AND c1.DATE_PARTITION = <YYYYMMDD>"
  activation:
    snowflake_collaborator: "CONSUMER"
    segment_name: "<segment_name>"
';

  CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.RUN('<collab>', :spec) INTO :result;
  RETURN :result;
END;
```

### Step C-10: Materialize flat table from VARIANT

```sql
CREATE OR REPLACE TABLE <local_db>.<schema>.ACTIVATION_RESULTS
CLUSTER BY (DATE_PARTITION) AS
SELECT
    RECORDS:ID:"p1.DATE_PARTITION"::NUMBER(8,0)  AS DATE_PARTITION,
    RECORDS:ID:"c1.<attr1>"::STRING              AS <attr1>,
    RECORDS:ID:"c1.<attr2>"::STRING              AS <attr2>,
    RECORDS:ID:"join_clause"::STRING             AS MATCH_CRITERIA,
    BATCH_ID, SEGMENT_NAME, UPDATED_ON
FROM SFDCR_<COLLAB>.ACTIVATION.SEGMENT_RECORDS
WHERE SEGMENT_NAME = '<segment_name>';
```

For 1000+ columns: build the projection list dynamically via Python or another Snowflake Scripting LISTAGG.

---

## Performance & Cost Benchmarks (Reference)

Tested on a real workload: **provider 1.2B rows × 1001 cols (8 weekly partitions × 150M)**, **consumer 8M rows × 7 cols**, hashed phone join key. All durations measured from `INFORMATION_SCHEMA.QUERY_HISTORY`. `secure_run_v2` is the dominant native-app stored proc.

| # | Scope | Cols/rec | Warehouse | Rows Exported | Wall Time | Credits | $ (std @ $3.90) |
|---|---|---:|---|---:|---:|---:|---:|
| 1 | 1-part analysis | 6 | XL | 3 (agg) | **39 s** | 0.17 | $0.67 |
| 2 | 8-part analysis (single query) | 6 | XL | 3 (agg) | **57 s** | 0.25 | $0.99 |
| 3 | 1-part activation | 6 | XL | 700k | **79 s** | 0.35 | $1.37 |
| 4 | 8-part activation (single query) | 6 | XL | 44.8M | **79 s** | 0.35 | $1.37 |
| 5 | 1-part activation | **1007** | XL | 700k | **71 min** | **19.04** | $74.3 |
| 6 | 8-part activation (single query) | **1007** | XL | 44.8M | **83 min** | **22.2** | $86.6 |
| 7 | 8-part activation (single query) | **1007** | 2XL | 44.8M | **45 min** | **23.8** | $93.0 |
| 8 | 1-part activation | **1007** | 2XL | 700k | **38 min** | **20.35** | $79.4 |

### Key Insights

1. **`secure_run_v2` dominates >93% of activation time** for wide-column activation. It's not the data scan but the VARIANT serialization framework that's the bottleneck.

2. **Column count scales NON-linearly**: 6 → 1007 columns = **63× slower**. Wide-column activation is genuinely expensive.

3. **Row count scales SUB-linearly**: 700k → 44.8M rows (64× more) = only **1.18× slower**. Once you've paid the framework cost for 1007 cols, adding partitions is cheap.

4. **Warehouse sizing** (XL → 2XL): **1.86× speedup, +6.9% credits**. 2XL is the sweet spot for SLA-sensitive wide-column workloads. Beyond 2XL → diminishing returns (write phase doesn't scale).

5. **Single-query (no partition filter) vs per-partition loop**: 5× faster, 80% cheaper credits. Output rows differ (cartesian expansion across partitions for single-query simple-key join), but **unique audience tuples after `SELECT DISTINCT` are identical**. Recommended: single-query + dedup downstream.

6. **Composite join (`p1.X=c1.X AND p1.DATE_PARTITION=c1.DATE_PARTITION`) is REJECTED** by template policy because `DATE_PARTITION` cannot be `join_standard`. Workarounds:
   - (a) Single key + DISTINCT downstream (simplest, recommended)
   - (b) Per-partition loop with `where_clause` filter (composite semantics, slower)
   - (c) Pre-compute composite hash column (e.g., `SHA2(MSISDN || '|' || DATE_PARTITION, 256)`) and register it as a `hashed_phone_sha256` join_standard column

### Production Recommendations

| Use Case | Recommended Pattern | Rough Cost |
|---|---|---:|
| **Daily campaign targeting (5-10 attrs)** | 6-col activation @ XL, single-query, downstream DISTINCT | < 0.5 credits |
| **Weekly C360 ML feature export (1000+ cols)** | Wide-col activation @ 2XL, scope to 1 partition at a time | ~20 credits |
| **Audience reach analysis (k-anon overlap counts)** | analysis-only template, no activation | < 0.3 credits |
| **Real-time / interactive lookup** | NOT a fit — activation has minutes-scale latency. Use a materialized view + secure share instead. |

---

## Cleanup

Re-register a spec with same name+version → overwrite. To drop a collaboration:

```sql
CALL SAMOOHA_BY_SNOWFLAKE_LOCAL_DB.COLLABORATION.DROP('<local_name>');
```

(If procedure doesn't exist in your version, contact Snowflake support.)

Suspend DCR-related warehouses when idle:

```sql
ALTER WAREHOUSE SAMOOHA_TASK_WAREHOUSE SUSPEND;
```

---

## Reference Implementation

A complete working reference is available at:

**Repo**: [github.com/arzamuhammad/dcr-collaboration-api](https://github.com/arzamuhammad/dcr-collaboration-api)

Includes:
- `01_provider_data/` — synthetic 1.2B-row partitioned C360 generator
- `02_consumer_data/` — 8M-row audience generator (deterministic SHA-256 overlap control = 70% match rate verified)
- `03_provider_notebook/provider_workflow.sql` — full provider SQL
- `04_consumer_notebook/consumer_workflow.sql` — full consumer SQL with single-query, full-columns, and dynamic-spec patterns
- `04_consumer_notebook/helpers/` — Python helpers for spec building & flat-table materialization
- `benchmark_results.md` — every benchmark in this playbook, raw + analyzed
- `medium.md` — narrative blog version with architecture diagrams

---

## Document History

This playbook is distilled from a real DCR build: 1.2B-row × 8M-row audience overlap with 1000+ activation columns, full benchmarks across XL/2XL warehouses, and 8 production gotchas resolved.

Made by working through every error so you don't have to.
