# staging/stg_raw_customers.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; infer from orchestration metadata
- **Owner:** Not specified in code; infer from data governance system

---

## Purpose

This component ingests raw customer records from the CRM export (stored in S3 via Redshift Spectrum) and prepares them for downstream analytics and reporting. It deduplicates customer records, applies PII masking to comply with privacy regulations, and standardizes data types and formats. The output serves as the single source of truth for customer dimensions in the analytics layer, enabling secure access to customer data for analytics teams while protecting sensitive personal information.

---

## Inputs

| Source | Purpose | Notes |
|--------|---------|-------|
| **spectrum.raw_customers** | Raw customer records exported from CRM system (S3 CSV via Redshift Spectrum) | Contains unstructured, potentially duplicate records with PII in plaintext. Updated incrementally; this layer deduplicates by keeping the most recent record per customer. |

---

## Outputs

| Target | Contents | Consumers |
|--------|----------|-----------|
| **staging.stg_raw_customers** | Deduplicated, PII-masked customer dimension table with 15 columns including customer ID, masked contact info, location, registration metadata, and engagement flags. Distributed by `customer_id` for efficient joins. | Downstream fact tables (orders, events, subscriptions), analytics dashboards, customer segmentation models, BI tools with `analytics_readers` group access. |

---

## Key Business Logic

### 1. **Deduplication by Most Recent Record**
```
ROW_NUMBER() OVER (PARTITION BY c.id ORDER BY c.updated_at DESC)
WHERE _row_num = 1
```
- **Why:** CRM exports may contain multiple versions of the same customer (e.g., from incremental syncs, corrections, or system errors).
- **Logic:** Ranks all records for each `customer_id` by `updated_at` descending, then keeps only the first (most recent). This ensures a 1:1 customer-to-row relationship.
- **Business Impact:** Prevents double-counting in downstream aggregations and ensures metrics reflect the latest customer state.

### 2. **PII Masking for Compliance**
Three masking strategies are applied:

| Field | Masking Strategy | Rationale |
|-------|------------------|-----------|
| **email** | MD5 hash + domain extraction | Hash enables joins/deduplication without exposing plaintext email. Domain retained for cohort analysis (e.g., corporate vs. consumer email providers). |
| **first_name / last_name** | First character + `***` | Allows name-based analytics (e.g., "J***" cohorts) while obscuring full identity. |
| **phone** | Country prefix only (first 3 chars) | Enables geographic/telecom analysis without exposing full phone numbers. |
| **postal_code** | First 3 characters + `***` | Preserves regional analysis capability while preventing precise address identification. |

- **Why:** Reduces risk of PII exposure in analytics environments; complies with GDPR, CCPA, and internal data governance policies.
- **Assumption:** Downstream consumers do not need plaintext PII; if they do, they access via a separate, access-controlled PII table.

### 3. **Data Validation & Filtering**
```
WHERE c.id IS NOT NULL
  AND c.email IS NOT NULL
  AND LEN(c.email) > 3
```
- **Why:** Excludes incomplete or malformed records that would cause downstream join failures or skew metrics.
- **Logic:** Requires non-null customer ID and email; email must be > 3 characters (basic format validation).
- **Business Impact:** Ensures only valid customers are included in analytics; reduces noise in segmentation and reporting.

### 4. **Default Value Handling**
```
NVL(c.marketing_opt_in, FALSE)
NVL(c.loyalty_tier, 'Bronze')
NVL(reported_ltv, 0)
```
- **Why:** Standardizes missing values to sensible defaults rather than NULLs, which simplify downstream aggregations and prevent NULL-related bugs.
- **Assumptions:**
  - Missing `marketing_opt_in` → customer has NOT opted in (conservative default for compliance).
  - Missing `loyalty_tier` → customer defaults to 'Bronze' (lowest tier).
  - Missing `reported_ltv` → customer has $0 lifetime value (conservative for revenue forecasting).

### 5. **Derived Metrics**
```
DATEDIFF(day, registration_date, GETDATE()) AS days_since_registration
```
- **Why:** Calculates customer tenure at load time for cohort analysis and lifecycle segmentation.
- **Note:** This is a point-in-time metric; it changes daily. Downstream consumers should be aware that this value is relative to the load date, not a fixed historical attribute.

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **customer_id** | BIGINT | Unique customer identifier from CRM. Primary key. | `12345`, `67890` |
| **email_hash** | VARCHAR(32) | MD5 hash of lowercased, trimmed email address. Enables PII-free joins and deduplication. | `5d41402abc4b2a76b9719d911017c592` |
| **email_domain** | VARCHAR(256) | Domain portion of email address (after `@`). Useful for B2B vs. B2C segmentation. | `gmail.com`, `acme.com`, `company.co.uk` |
| **first_name_masked** | VARCHAR(4) | First character of first name + `***`. Preserves name-based cohorts while masking identity. | `J***`, `S***` |
| **last_name_masked** | VARCHAR(4) | First character of last name + `***`. | `D***`, `S***` |
| **phone_country_prefix** | VARCHAR(3) | First 3 characters of phone number (typically country code). Enables geographic analysis. | `+1`, `+44`, `+33` |
| **country** | VARCHAR(2) | ISO 3166-1 alpha-2 country code. | `US`, `GB`, `DE`, `CA` |
| **state** | VARCHAR(50) | State/province name or code. | `CA`, `NY`, `ON`, `BC` |
| **city** | VARCHAR(100) | City name. | `San Francisco`, `London`, `Toronto` |
| **postal_code_masked** | VARCHAR(6) | First 3 characters of postal code + `***`. Enables regional analysis without precise address. | `94***`, `SW1***`, `M5***` |
| **registration_date** | DATE | Date customer first registered/created in CRM. Used for cohort analysis and tenure calculations. | `2023-01-15`, `2024-06-20` |
| **last_login_date** | DATE | Date of customer's most recent login. Indicates engagement/churn risk. | `2024-12-01`, `2024-11-15` |
| **marketing_opt_in** | BOOLEAN | Whether customer has opted into marketing communications. Defaults to FALSE if null. | `TRUE`, `FALSE` |
| **loyalty_tier** | VARCHAR(20) | Customer loyalty program tier. Defaults to 'Bronze' if null. | `Bronze`, `Silver`, `Gold`, `Platinum` |
| **reported_ltv** | DECIMAL(12,2) | Lifetime value reported by CRM system. Defaults to 0 if null. Used for customer segmentation and prioritization. | `1250.50`, `0.00`, `45000.00` |
| **days_since_registration** | INT | Number of days between registration and load date. Derived metric for tenure-based analysis. | `365`, `180`, `1` |
| **_loaded_at** | TIMESTAMP | Timestamp when this record was loaded into staging. Enables point-in-time analysis and auditing. | `2024-12-15 02:30:00` |

---

## Data Quality & Edge Cases

### Null Handling
| Field | Null Behavior | Rationale |
|-------|---------------|-----------|
| **customer_id, email** | Excluded via WHERE clause | These are required for deduplication and joins; records without them are invalid. |
| **marketing_opt_in, loyalty_tier, reported_ltv** | Replaced with defaults (FALSE, 'Bronze', 0) | Prevents downstream NULL propagation; defaults are conservative (privacy-safe, revenue-safe). |
| **last_login_date** | Allowed to be NULL | Not all customers have logged in; NULL indicates no login history. |
| **state, city, postal_code** | Allowed to be NULL | Some customers may not have complete address data; masking still applied if present. |

### Deduplication Strategy
- **Method:** ROW_NUMBER with PARTITION BY customer_id, ORDER BY updated_at DESC
- **Assumption:** `updated_at` timestamp is reliable and monotonically increasing per customer.
- **Risk:** If `updated_at` is not populated or is incorrect in source data, deduplication may keep stale records.
- **Mitigation:** Validate `updated_at` distribution in upstream data quality checks.

### Data Assumptions
1. **Email uniqueness:** Assumes email addresses are unique identifiers (one email per customer). If customers share emails, deduplication may fail.
2. **Country codes:** Assumes `country` field contains valid ISO 3166-1 alpha-2 codes. Invalid codes will not be caught.
3. **Date formats:** Assumes `created_at` and `last_login` are valid timestamps; CONVERT(DATE, ...) will fail if format is unexpected.
4. **Phone format:** Assumes phone numbers start with country code (e.g., `+1...`). If format varies, `LEFT(phone_raw, 3)` may extract incorrect data.
5. **Postal code format:** Assumes postal codes are at least 3 characters. Shorter codes will be masked as `X***` (potentially invalid).

### What Could Break
| Scenario | Impact | Mitigation |
|----------|--------|-----------|
| **Duplicate emails in source** | Deduplication by ID still works, but email_hash may not be unique. Downstream joins on email_hash could fail or produce duplicates. | Add uniqueness constraint on email_hash; validate in upstream data quality. |
| **Missing or malformed updated_at** | ROW_NUMBER ordering becomes non-deterministic; may keep arbitrary records instead of most recent. | Validate updated_at is NOT NULL and is a valid timestamp. |
| **Email format changes** (e.g., special characters, unicode) | MD5 hash may not be consistent; SPLIT_PART may fail if `@` is missing. | Validate email format in upstream; add error handling for malformed emails. |
| **Phone/postal code format inconsistency** | Masking logic assumes fixed positions; may extract wrong data if formats vary. | Standardize formats in upstream or add conditional logic for multiple formats. |
| **Timezone issues** | GETDATE() returns server time; `days_since_registration` may be off by 1 day depending on server timezone. | Use UTC-normalized timestamps; document timezone assumption. |

---

## Performance Notes

### Distribution & Sorting
```
DISTKEY(customer_id)
SORTKEY(customer_id)
```
- **Why DISTKEY(customer_id)?** Ensures all rows for a customer are co-located on the same node, enabling efficient joins with fact tables (orders, events) that also use customer_id as a join key. Reduces network traffic (shuffle) during joins.
- **Why SORTKEY(customer_id)?** Enables fast range scans and joins on customer_id; Redshift can skip blocks during queries filtering by customer_id.
- **Trade-off:** Slows INSERT/UPDATE operations slightly due to sort maintenance, but dramatically speeds downstream queries (which are more frequent).

### Join Strategy
```
FROM spectrum.raw_customers c
```
- **Type:** Spectrum external table scan (S3 CSV via Redshift Spectrum).
- **Cost:** Slower than native Redshift tables; each query scans S3. No indexes available.
- **Optimization:** This staging layer materializes the data into a native Redshift table, so downstream queries are fast. The cost is paid once during this ETL step, not repeatedly.

### Expensive Operations
| Operation | Cost | Mitigation |
|-----------|------|-----------|
| **ROW_NUMBER() window function** | O(n log n) sort per partition. For large customer bases (millions), this is non-trivial. | Acceptable; deduplication is a one-time cost. If source data is already deduplicated, consider removing this step. |
| **MD5 hashing** | O(n) string hashing. Minimal cost per row. | Acceptable; negligible compared to I/O. |
| **SPLIT_PART on email** | O(n) string operation. Minimal cost. | Acceptable. |
| **DATEDIFF calculation** | O(n) date arithmetic. Minimal cost. | Acceptable; could be moved to downstream layer if load time is critical. |

### Estimated Query Time
- **Source:** ~1M customers in S3 CSV (Spectrum scan)
- **Deduplication:** ~30-60 seconds (window function + sort)
- **Masking & transformation:** ~10-20 seconds (string operations)
- **Total:** ~1-2 minutes for full refresh
- **Optimization:** If incremental loads are needed, consider loading only changed records (delta) instead of full refresh.

### Storage
- **Uncompressed size:** ~1M customers × ~500 bytes/row ≈ 500 MB
- **Compressed (Redshift default):** ~100-150 MB
- **Acceptable for staging layer.**

---

## Dependencies

### Upstream
| Component | Type | Why Required | Failure Impact |
|-----------|------|--------------|-----------------|
| **spectrum.raw_customers** | External table (S3 CSV) | Source of all customer data. | If S3 file is missing, deleted, or malformed, this query fails. If file is empty, output table is empty. |
| **CRM export process** | External system | Produces the S3 CSV that Spectrum reads. | If CRM export fails or is delayed, this staging layer has stale data. |

### Downstream
| Component | Type | Why Dependent | Impact if This Fails |
|-----------|------|--------------|----------------------|
| **mart.dim_customers** | Dimension table | Consumes `stg_raw_customers` to build the final customer dimension. | Dimension table cannot be refreshed; all fact tables that join to customers are blocked. |
| **mart.fct_orders** | Fact table | Joins to `stg_raw_customers` on customer_id to enrich orders with customer attributes. | Orders cannot be enriched with customer data; customer-level aggregations fail. |
| **analytics dashboards** (e.g., customer segmentation, cohort analysis) | BI tools | Query `stg_raw_customers` (or downstream marts) for customer attributes. | Dashboards show stale or missing customer data. |
| **customer segmentation models** | ML/analytics | Use `stg_raw_customers` features (loyalty_tier, days_since_registration, marketing_opt_in) for clustering. | Models cannot be retrained; predictions become stale. |

### External
| System | Purpose | Notes |
|--------|---------|-------|
| **AWS S3** | Storage for raw CRM export CSV | Redshift Spectrum reads from S3; if S3 is unavailable or permissions are revoked, queries fail. |
| **Redshift Spectrum** | External table layer | Enables querying S3 data as if it were a Redshift table. If Spectrum is misconfigured or S3 path is wrong, queries fail. |
| **Redshift IAM role** | Permissions to read S3 | Must have s3:GetObject on the CRM export bucket. If role is missing or permissions are revoked, queries fail. |

---

## Maintenance & Monitoring

### Recommended Checks
- **Row count trend:** Monitor for unexpected drops (indicates upstream data loss) or spikes (indicates duplicate records).
- **Email hash uniqueness:** Validate that email_hash is unique (or document if duplicates are expected).
- **NULL rates:** Track percentage of NULLs in each column; sudden increases indicate upstream data quality issues.
- **Load time:** Monitor query execution time; if it exceeds SLA, investigate Spectrum performance or data volume growth.
- **Downstream join success rate:** Monitor for join failures in downstream fact tables; indicates deduplication or key issues.

### Refresh Frequency
- Not specified in code; infer from orchestration metadata (e.g., Airflow DAG, dbt schedule).
- Recommend: Daily full refresh (or incremental if source supports it).

### Access Control
```
GRANT SELECT ON staging.stg_raw_customers TO GROUP analytics_readers;
```
- Only `analytics_readers` group can query this table.
- PII is masked, so this is safe for general analytics access.
- If plaintext PII is needed, create a separate, access-controlled table with stricter permissions.