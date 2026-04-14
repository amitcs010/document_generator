# staging/stg_raw_customers.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; infer from orchestration layer
- **Owner:** Not specified in code; recommend documenting in dbt project or Airflow DAG metadata

---

## Purpose

This component ingests raw customer records from the CRM export (stored in S3 via Redshift Spectrum) and prepares them for downstream analytics and reporting. It deduplicates customer records by keeping the most recent version, applies PII masking to comply with privacy requirements, and standardizes data types and formats. The output serves as the single source of truth for customer dimensions in the analytics layer, enabling BI teams, marketing analysts, and data scientists to safely access customer data without exposing sensitive personal information.

---

## Inputs

| Source | Purpose | Notes |
|--------|---------|-------|
| **spectrum.raw_customers** | Raw customer records exported from CRM system (S3 CSV via Redshift Spectrum) | Contains undeduped, unmasked PII; updated daily or on-demand. Schema includes: `id`, `email`, `first_name`, `last_name`, `phone`, `country`, `state`, `city`, `postal_code`, `created_at`, `last_login`, `updated_at`, `marketing_opt_in`, `loyalty_tier`, `lifetime_value`. |

---

## Outputs

| Target | Contents | Consumers |
|--------|----------|-----------|
| **staging.stg_raw_customers** | Deduplicated, PII-masked customer dimension table with 16 columns. One row per unique `customer_id`. Includes registration metadata, geographic info, loyalty tier, and engagement flags. | Downstream analytics models (e.g., `marts.dim_customers`), BI dashboards, marketing automation workflows, customer segmentation analyses. Read access granted to `analytics_readers` group. |

---

## Key Business Logic

### 1. **Deduplication by Most Recent Record**
**What:** The CTE `ranked` uses `ROW_NUMBER() OVER (PARTITION BY c.id ORDER BY c.updated_at DESC)` to assign a rank to each customer record, with rank 1 being the most recently updated. The final SELECT filters to `WHERE _row_num = 1`, keeping only the latest version.

**Why:** The raw CRM export may contain multiple versions of the same customer (e.g., if records are updated incrementally or re-exported with overlaps). Keeping only the most recent ensures the analytics layer reflects the current state of each customer without duplicates or stale information.

**Edge case:** If `updated_at` is NULL or missing, the ordering becomes non-deterministic. The code assumes `updated_at` is always populated; if not, add explicit NULL handling (e.g., `COALESCE(c.updated_at, c.created_at)`).

---

### 2. **PII Masking for Compliance**
**What:** Sensitive fields are transformed:
- **Email:** Hashed with MD5 (lowercase, trimmed) to `email_hash`; domain extracted separately to `email_domain` for analytics.
- **Name:** First and last names masked to first initial + `***` (e.g., `J***`, `D***`).
- **Phone:** Only country prefix (first 3 digits) retained; full number discarded.
- **Postal code:** First 3 characters retained, remainder masked with `***`.

**Why:** Protects customer PII from unauthorized access while preserving analytical utility. Email domain enables cohort analysis (e.g., corporate vs. consumer domains). Postal code prefix supports geographic analysis without exposing exact addresses. This design assumes compliance requirements (GDPR, CCPA, internal policy) prohibit storing full PII in analytics.

**Assumption:** MD5 hashing is acceptable for this use case. If deterministic hashing is required for joins with other systems, MD5 is suitable; if cryptographic security is needed, consider SHA-256 or a key-based encryption function.

---

### 3. **Null Handling & Defaults**
**What:**
- `NVL(c.marketing_opt_in, FALSE)` — defaults opt-in flag to FALSE if missing.
- `NVL(c.loyalty_tier, 'Bronze')` — defaults tier to 'Bronze' if missing.
- `NVL(reported_ltv, 0)` — defaults lifetime value to 0 if missing.

**Why:** Ensures no NULL values in key business dimensions, preventing downstream query failures and enabling consistent aggregations. Defaults are conservative (opt-out, lowest tier, zero value) to avoid overstating engagement or revenue.

**Risk:** If NULL values have semantic meaning (e.g., "tier not yet assigned" vs. "Bronze tier"), this logic conflates them. Recommend documenting the business rule with stakeholders.

---

### 4. **Data Type Casting & Standardization**
**What:** All columns are explicitly cast to target types (BIGINT, VARCHAR, DATE, DECIMAL). Dates are converted using `CONVERT(DATE, ...)` to strip time components.

**Why:** Ensures consistent schema across environments and prevents implicit type coercion errors in downstream queries. Explicit casting also documents expected data types for consumers.

**Assumption:** Source data types are compatible with target types (e.g., `c.id` can be cast to BIGINT without overflow).

---

### 5. **Calculated Metrics**
**What:** `days_since_registration = DATEDIFF(day, registration_date, GETDATE())` computes tenure at load time.

**Why:** Provides a snapshot of customer age for segmentation and cohort analysis. Recalculated on each load to reflect current date.

**Limitation:** This is a point-in-time metric; historical tenure is not preserved. For time-series analysis, consider storing this in a fact table instead.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **customer_id** | BIGINT | Unique customer identifier from CRM. Primary key. | `12345678` |
| **email_hash** | VARCHAR(32) | MD5 hash of lowercased, trimmed email. Used for privacy-safe joins and deduplication. | `5d41402abc4b2a76b9719d911017c592` |
| **email_domain** | VARCHAR(256) | Domain portion of email address (after `@`). Enables B2B vs. B2C segmentation. | `gmail.com`, `company.com` |
| **first_name_masked** | VARCHAR(4) | First initial + `***`. Preserves minimal PII for customer service workflows. | `J***`, `S***` |
| **last_name_masked** | VARCHAR(4) | Last initial + `***`. | `D***`, `M***` |
| **phone_country_prefix** | VARCHAR(3) | First 3 digits of phone number (country/region code). | `+1`, `+44` |
| **country** | VARCHAR(2) | ISO 3166-1 alpha-2 country code. | `US`, `GB`, `CA` |
| **state** | VARCHAR(50) | State/province name or code. | `CA`, `NY`, `ON` |
| **city** | VARCHAR(100) | City name. | `San Francisco`, `Toronto` |
| **postal_code_masked** | VARCHAR(6) | First 3 characters of postal code + `***`. Supports regional analysis without exposing exact address. | `94***`, `M5V***` |
| **registration_date** | DATE | Date customer account was created. | `2023-01-15` |
| **last_login_date** | DATE | Date of most recent login. NULL if never logged in. | `2024-01-10` |
| **marketing_opt_in** | BOOLEAN | Whether customer has opted into marketing communications. Defaults to FALSE. | `TRUE`, `FALSE` |
| **loyalty_tier** | VARCHAR(50) | Customer loyalty program tier. Defaults to 'Bronze'. | `Bronze`, `Silver`, `Gold`, `Platinum` |
| **reported_ltv** | DECIMAL(12,2) | Lifetime value as reported by CRM. Defaults to 0. May not reflect actual revenue. | `1250.50`, `0.00` |
| **days_since_registration** | INT | Number of days between registration and load date. Recalculated on each load. | `365`, `1` |
| **_loaded_at** | TIMESTAMP | Timestamp when this record was loaded into staging. Used for audit trails and incremental logic. | `2024-01-20 14:30:00` |

---

## Data Quality & Edge Cases

### Null Handling
| Field | Behavior | Risk |
|-------|----------|------|
| `customer_id` | Filtered out (`WHERE c.id IS NOT NULL`). | If CRM exports records with NULL IDs, they are silently dropped. Recommend alerting if row count drops unexpectedly. |
| `email` | Filtered out (`WHERE c.email IS NOT NULL AND LEN(c.email) > 3`). | Customers without email are excluded. If CRM adds phone-only customers, they will not appear in this table. |
| `updated_at` | Used for deduplication ranking. If NULL, ordering is non-deterministic. | If CRM stops populating `updated_at`, deduplication may select arbitrary records. Recommend adding explicit NULL check or fallback to `created_at`. |
| `marketing_opt_in`, `loyalty_tier`, `reported_ltv` | Defaulted to FALSE, 'Bronze', 0 respectively. | Conflates missing data with explicit values. Recommend adding a separate `_is_null_*` flag if semantic distinction is important. |
| `last_login_date` | May be NULL if customer never logged in. | Downstream queries must handle NULL explicitly (e.g., `COALESCE(last_login_date, registration_date)`). |

### Deduplication Strategy
- **Method:** ROW_NUMBER with PARTITION BY customer_id, ORDER BY updated_at DESC.
- **Assumption:** `updated_at` is always populated and reflects record recency.
- **Limitation:** If two records have identical `updated_at`, the order is arbitrary (depends on table scan order). Recommend adding a tiebreaker (e.g., `ORDER BY updated_at DESC, id DESC`).
- **Impact:** Exactly one row per customer_id is guaranteed.

### Data Assumptions
1. **Email uniqueness:** Code assumes email is a valid identifier. If one customer has multiple emails or one email belongs to multiple customers, deduplication may fail.
2. **Country/state codes:** Assumes `country` is ISO 3166-1 alpha-2 (2-letter code). If CRM uses full country names, validation will fail downstream.
3. **Postal code format:** Assumes postal codes are at least 3 characters. If any are shorter, masking will fail or produce unexpected results.
4. **Phone format:** Assumes phone numbers start with country code (e.g., `+1` for US). If format varies, `LEFT(phone_raw, 3)` may extract inconsistent prefixes.
5. **Lifetime value accuracy:** `reported_ltv` is sourced from CRM and may not match actual revenue. Recommend reconciling with billing system in a separate quality check.

### What Could Break
- **Upstream schema changes:** If CRM adds/removes/renames columns, the SELECT list will fail. Recommend adding a schema validation step before this query.
- **Data type mismatches:** If `c.id` exceeds BIGINT range or `c.email` exceeds 256 characters, casting will fail or truncate.
- **Encoding issues:** If raw CSV contains non-UTF-8 characters, MD5 hashing may produce inconsistent results. Recommend normalizing encoding in the Spectrum table definition.
- **Timezone issues:** `GETDATE()` returns server time. If Redshift cluster is in a different timezone than CRM, `days_since_registration` may be off by 1 day. Recommend using `GETDATE() AT TIME ZONE 'UTC'` for consistency.
- **Email validation:** Code does not validate email format (e.g., `test@test` passes the length check). Recommend adding regex validation if strict compliance is required.

---

## Performance Notes

### Distribution & Sort Keys
- **DISTKEY(customer_id):** Distributes rows across cluster nodes by customer_id. Ensures that all records for a given customer land on the same node, optimizing joins on customer_id in downstream queries.
- **SORTKEY(customer_id):** Sorts rows within each node by customer_id. Enables efficient range scans and merge joins on customer_id.
- **Rationale:** Customer_id is the primary join key in downstream models (e.g., `dim_customers`, `fct_orders`). Co-locating and sorting by this key minimizes data movement during joins.

### Join Strategy
- **No explicit joins:** This query reads from a single source table (spectrum.raw_customers). No join performance concerns.
- **Spectrum overhead:** Reading from S3 via Spectrum is slower than native Redshift tables. If this query runs frequently, consider materializing raw_customers as a native Redshift table.

### Window Function Efficiency
- **ROW_NUMBER() OVER (PARTITION BY c.id ORDER BY c.updated_at DESC):** This is a full-table scan with a sort operation. For large customer bases (millions of records), this can be expensive.
- **Optimization:** If raw_customers is already sorted by id and updated_at, Redshift can optimize this. Recommend adding a SORTKEY to the Spectrum table definition if possible.
- **Alternative:** If deduplication is not required (i.e., raw_customers is already deduplicated), remove the CTE and window function to improve performance.

### Materialization & Indexing
- **CREATE TABLE AS:** Materializes the result as a new table. This is a full rebuild on each run, not an incremental update.
- **Implication:** For large customer bases, this can take minutes. If incremental updates are needed, consider using `INSERT INTO ... SELECT` with a WHERE clause on `_loaded_at` or `updated_at`.
- **ANALYZE:** The final `ANALYZE` statement updates table statistics. This is necessary for query planner optimization but adds overhead.

### Estimated Row Count & Size
- Assuming 1M customers, ~16 columns, ~500 bytes per row → ~8 GB table size.
- Full rebuild time: ~30–60 seconds (depending on cluster size and Spectrum latency).
- Recommend monitoring query execution time and alerting if it exceeds SLA.

---

## Dependencies

### Upstream
| Component | Type | Criticality | Notes |
|-----------|------|-------------|-------|
| **spectrum.raw_customers** | External table (S3 CSV) | **Critical** | Must be populated by CRM export process before this query runs. If export fails or is delayed, this table will not refresh. Recommend adding a data freshness check (e.g., alert if `MAX(updated_at)` is older than 24 hours). |

### Downstream
| Component | Type | Dependency | Notes |
|-----------|------|-----------|-------|
| **marts.dim_customers** | Dimension table | Consumes `stg_raw_customers` as primary source. | Applies additional business logic (e.g., customer segmentation, RFM scoring). Depends on deduplication and PII masking from staging layer. |
| **fct_orders** | Fact table | Joins to `stg_raw_customers` on customer_id. | Enriches order records with customer attributes (e.g., loyalty tier, registration date). |
| **BI dashboards** (e.g., Customer 360, Cohort Analysis) | BI reports | Query `stg_raw_customers` directly or via `dim_customers`. | Analysts rely on masked PII and accurate deduplication. |
| **Marketing automation workflows** | External system | May consume customer list via export or API. | Requires accurate email_domain and marketing_opt_in flags. |
| **Data quality monitoring** | Monitoring/alerting | Tracks row count, NULL rates, and freshness. | Alerts if deduplication logic fails (e.g., row count unexpectedly drops). |

### External
| System | Purpose | Notes |
|--------|---------|-------|
| **Redshift Spectrum** | Query S3 data | Requires S3 bucket permissions and Spectrum table definition. If S3 path changes, query will fail. |
| **Redshift cluster** | Compute & storage | Requires sufficient disk space for materialized table. If cluster is near capacity, CREATE TABLE may fail. |
| **analytics_readers group** | Access control | GRANT statement assumes this group exists. If group is deleted, subsequent GRANT will fail. |

---

## Additional Recommendations

### Monitoring & Alerting
1. **Row count validation:** Alert if row count drops >10% from previous load (indicates deduplication issue or upstream data loss).
2. **Freshness check:** Alert if `MAX(_loaded_at)` is older than 24 hours.
3. **NULL rate tracking:** Monitor percentage of NULL values in key columns (e.g., `last_login_date`). Spike may indicate upstream schema change.
4. **Email domain distribution:** Track top 10 email domains. Sudden shift may indicate data quality issue.

### Documentation Gaps
- **Owner:** Recommend adding a comment with team name (e.g., `-- Owner: Data Platform Team`).
- **Schedule:** Recommend adding a comment with refresh frequency (e.g., `-- Refreshed daily at 02:00 UTC`).
- **SLA:** Recommend documenting acceptable latency (e.g., `-- SLA: Must complete within 5 minutes`).
- **Masking rationale:** Recommend documenting compliance requirement (e.g., `-- PII masking required by GDPR Article 32`).

### Future Enhancements
1. **Incremental refresh:** Replace full rebuild with incremental INSERT based on `updated_at` to improve performance.
2. **Data quality checks:** Add pre-query validation (e.g., row count, schema, data types) to catch upstream issues early.
3. **Audit trail:** Add columns for `_source_file`, `_extract_date` to track data lineage.
4. **Customer status:** Add a `customer_status` column (e.g., 'Active', 'Inactive', 'Churned') based on `last_login_date` and `registration_date`.
5. **Email validation:** Add regex check to filter invalid email formats before hashing.