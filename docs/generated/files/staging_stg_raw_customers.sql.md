# staging/stg_raw_customers.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; infer from orchestration metadata
- **Owner:** Not specified in code; infer from data governance system

---

## Purpose

This component ingests raw customer records from the CRM export (stored in S3 via Redshift Spectrum) and prepares them for downstream analytics and reporting. It deduplicates customer records, applies PII masking to comply with privacy regulations, and standardizes data types and formats. The output serves as the single source of truth for customer master data across the analytics layer, enabling secure access for analytics teams while protecting sensitive personal information.

---

## Inputs

| Source | Purpose | Notes |
|--------|---------|-------|
| **spectrum.raw_customers** | Raw customer records exported from CRM system (S3 CSV via Redshift Spectrum) | Contains undeduped, unmasked customer data with timestamps for change tracking. Expected to have daily or near-real-time updates. |

---

## Outputs

| Target | Contents | Consumers |
|--------|----------|-----------|
| **staging.stg_raw_customers** | Deduplicated, PII-masked customer master records with computed derived fields (registration tenure, email domain, etc.). One row per unique customer_id. | Downstream analytics models, BI dashboards, customer segmentation logic, reporting views. Accessible to `analytics_readers` group. |

---

## Key Business Logic

### 1. **Deduplication by Most Recent Record**
```
ROW_NUMBER() OVER (PARTITION BY c.id ORDER BY c.updated_at DESC)
```
- **Why:** CRM exports may contain multiple versions of the same customer (e.g., from incremental syncs, corrections, or system errors).
- **Logic:** Ranks all records for each `customer_id` by `updated_at` descending, then filters to `_row_num = 1` to keep only the latest version.
- **Assumption:** `updated_at` is reliable and monotonically increasing. If timestamps are unreliable or missing, deduplication may fail silently.

### 2. **Data Validation & Filtering**
```
WHERE c.id IS NOT NULL
  AND c.email IS NOT NULL
  AND LEN(c.email) > 3
```
- **Why:** Ensures only valid, identifiable customer records are included. Prevents null keys and obviously malformed emails.
- **Edge case:** Does not validate email format (e.g., `a@b` passes the length check but is invalid). Consider adding regex validation if data quality issues arise.

### 3. **PII Masking for Compliance**
- **Email:** Hashed with MD5 (lowercase, trimmed) for analytics joins; domain extracted separately for segmentation.
  - **Why:** Allows analytics on email domain (e.g., corporate vs. consumer) without exposing full email addresses.
  - **Risk:** MD5 is cryptographically weak; consider SHA-256 for higher security.
- **Name fields:** First and last names masked to initial + `***` (e.g., `J***`, `D***`).
  - **Why:** Prevents direct identification while preserving initial for debugging/validation.
- **Phone:** Only country prefix (first 3 digits) retained; full number discarded.
  - **Why:** Enables geographic analysis without exposing contact information.
- **Postal code:** First 3 characters + `***` (e.g., `90210***`).
  - **Why:** Allows regional analysis (e.g., zip code prefix for marketing) without full precision.

### 4. **Null Handling & Defaults**
```
NVL(c.marketing_opt_in, FALSE)
NVL(c.loyalty_tier, 'Bronze')
NVL(reported_ltv, 0)
```
- **Why:** Ensures no null values in key business fields; missing opt-in defaults to FALSE (conservative), missing tier defaults to 'Bronze' (baseline), missing LTV defaults to 0 (no revenue).
- **Assumption:** These defaults reflect business policy. If not, they should be reviewed with product/business stakeholders.

### 5. **Derived Metrics**
```
DATEDIFF(day, registration_date, GETDATE()) AS days_since_registration
```
- **Why:** Computes customer tenure at load time for cohort analysis and lifecycle segmentation.
- **Note:** This is a point-in-time metric; it changes with each load. For historical analysis, consider storing as a slowly changing dimension (SCD Type 2).

### 6. **Type Casting & Standardization**
- All string fields cast to explicit VARCHAR lengths (e.g., `VARCHAR(256)` for email).
- Dates converted from raw timestamps to DATE type (time component dropped).
- Numeric fields cast to DECIMAL(12,2) for financial precision.
- **Why:** Ensures consistent schema, prevents downstream type coercion errors, and optimizes storage.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **customer_id** | BIGINT | Unique customer identifier from CRM. Primary key. | `12345678` |
| **email_hash** | VARCHAR(32) | MD5 hash of lowercased, trimmed email address. Used for joins and deduplication without exposing PII. | `5d41402abc4b2a76b9719d911017c592` |
| **email_domain** | VARCHAR(256) | Domain portion of email address (after `@`). Enables B2B vs. B2C segmentation. | `gmail.com`, `company.com` |
| **first_name_masked** | VARCHAR(4) | First initial + `***`. Supports debugging while protecting PII. | `J***`, `M***` |
| **last_name_masked** | VARCHAR(4) | Last initial + `***`. Supports debugging while protecting PII. | `D***`, `S***` |
| **phone_country_prefix** | VARCHAR(3) | First 3 digits of phone number (country/area code). Enables geographic analysis. | `415`, `212` |
| **country** | VARCHAR(2) | ISO 3166-1 alpha-2 country code. | `US`, `CA`, `GB` |
| **state** | VARCHAR(50) | State or province name/code. | `CA`, `NY`, `ON` |
| **city** | VARCHAR(100) | City name. | `San Francisco`, `Toronto` |
| **postal_code_masked** | VARCHAR(6) | First 3 characters of postal code + `***`. Enables regional analysis without full precision. | `902***`, `M5V***` |
| **registration_date** | DATE | Date customer first registered in CRM. | `2023-01-15` |
| **last_login_date** | DATE | Date of most recent login/activity. | `2024-01-10` |
| **marketing_opt_in** | BOOLEAN | Whether customer has opted into marketing communications. Defaults to FALSE if null. | `TRUE`, `FALSE` |
| **loyalty_tier** | VARCHAR(50) | Customer loyalty program tier. Defaults to 'Bronze' if null. | `Bronze`, `Silver`, `Gold`, `Platinum` |
| **reported_ltv** | DECIMAL(12,2) | Lifetime value as reported by CRM. Defaults to 0 if null. | `1250.50`, `0.00` |
| **days_since_registration** | INT | Number of days between registration and load time. Computed at load time. | `365`, `1` |
| **_loaded_at** | TIMESTAMP | Timestamp when this record was loaded into staging. Used for audit trails and incremental logic. | `2024-01-20 14:30:00` |

---

## Data Quality & Edge Cases

### Null Handling
| Field | Null Behavior | Risk |
|-------|---------------|------|
| `customer_id` | Filtered out (WHERE c.id IS NOT NULL) | Customers with missing IDs are silently dropped. Monitor for unexpected volume loss. |
| `email` | Filtered out (WHERE c.email IS NOT NULL AND LEN > 3) | Customers without emails are excluded. May miss valid records if email is optional in CRM. |
| `marketing_opt_in` | Defaults to FALSE | Conservative default; may undercount opted-in customers if nulls represent unknown rather than false. |
| `loyalty_tier` | Defaults to 'Bronze' | Assumes all unspecified customers are baseline tier. Verify this reflects business policy. |
| `reported_ltv` | Defaults to 0 | Treats missing LTV as zero revenue. May conflate "unknown" with "no revenue." |
| `last_login_date` | Retained as null | Customers who have never logged in will have null. Downstream queries must handle this. |

### Deduplication Strategy
- **Method:** ROW_NUMBER() with PARTITION BY customer_id, ORDER BY updated_at DESC.
- **Assumption:** `updated_at` is always populated and reliable. If timestamps are missing or out of order, deduplication is non-deterministic.
- **Risk:** If multiple records have identical `updated_at`, the order is arbitrary (depends on physical row order). Consider adding a tiebreaker (e.g., `created_at DESC, id DESC`).

### Data Validation Gaps
| Issue | Current Check | Gap | Mitigation |
|-------|----------------|-----|-----------|
| Email format | Length > 3 only | Does not validate format (e.g., `a@b` passes) | Add regex: `email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z\|a-z]{2,}$'` |
| Phone format | No validation | Accepts any string; country prefix extraction may fail if format varies | Add length check or regex for phone format. |
| Postal code | No validation | Accepts any string; masking assumes >= 3 characters | Add length check before masking. |
| Country code | No validation | Accepts any string; should be ISO 3166-1 alpha-2 | Add check: `country IN (SELECT code FROM ref.iso_countries)` |
| Date ranges | No validation | `last_login_date` could be in future or before `registration_date` | Add check: `last_login_date >= registration_date AND last_login_date <= GETDATE()` |

### Assumptions About Upstream Data
1. **CRM exports daily or near-real-time** — If export frequency changes, load schedule must be adjusted.
2. **`updated_at` is reliable** — If timestamps are backfilled or corrected retroactively, deduplication may select wrong record.
3. **`id` is globally unique** — If CRM allows duplicate IDs or reuses IDs, deduplication fails.
4. **Email addresses are stable** — If customers can change email, historical joins on `email_hash` may break.
5. **Country/state/city codes are standardized** — If CRM uses inconsistent formats, downstream joins may fail.

### What Could Break
- **Upstream schema changes:** If CRM adds/removes/renames columns, the SELECT list will fail.
- **Data type changes:** If `id` becomes VARCHAR or `updated_at` format changes, casting will fail.
- **Null explosion:** If upstream starts populating previously-null fields differently, defaults may no longer apply.
- **Duplicate explosion:** If `updated_at` stops being populated, deduplication becomes non-deterministic.
- **PII masking failures:** If email/phone/postal_code fields contain unexpected formats (e.g., very short strings), masking functions may produce unexpected results.

---

## Performance Notes

### Distribution & Sorting Strategy
```
DISTKEY(customer_id)
SORTKEY(customer_id)
```
- **Why DISTKEY on customer_id:** Ensures all records for a customer are co-located on the same node. Optimizes joins on customer_id in downstream queries (e.g., joining with orders, transactions).
- **Why SORTKEY on customer_id:** Enables efficient range scans and joins. Redshift can skip blocks when filtering/joining on customer_id.
- **Trade-off:** If downstream queries frequently filter on `country` or `email_domain`, consider a compound SORTKEY: `SORTKEY(customer_id, country)`. Measure query performance before changing.

### Join Strategy in CTE
```
FROM spectrum.raw_customers c
```
- **Note:** Spectrum queries read directly from S3 without materializing in Redshift. This is I/O-intensive.
- **Performance:** Spectrum scans are slower than native Redshift tables. If this query runs frequently, consider materializing `spectrum.raw_customers` as a native Redshift table.

### Window Function (ROW_NUMBER)
```
ROW_NUMBER() OVER (PARTITION BY c.id ORDER BY c.updated_at DESC)
```
- **Cost:** Window functions require a full sort of the partition. For large customer bases (millions of records), this is expensive.
- **Optimization:** If deduplication is the bottleneck, consider:
  - Pre-filtering to recent records: `WHERE c.updated_at >= GETDATE() - INTERVAL '7 days'` (if only recent changes matter).
  - Using a materialized view of the latest snapshot from the CRM (if available).

### Full Table Scan
- **Current:** The query scans all of `spectrum.raw_customers` without partition pruning.
- **Optimization:** If the CRM export is partitioned by date in S3, add a WHERE clause to filter to recent data:
  ```sql
  WHERE c.updated_at >= GETDATE() - INTERVAL '1 day'
  ```
  This reduces Spectrum I/O significantly.

### String Operations (MD5, SPLIT_PART, LEFT)
- **Cost:** MD5 hashing and string functions are CPU-intensive. For millions of rows, this adds latency.
- **Optimization:** If hashing is slow, consider:
  - Pre-computing hashes in the CRM export (if possible).
  - Using a faster hash (e.g., SHA-256 in hardware).
  - Caching hashes in a lookup table.

### Estimated Query Runtime
- **Small dataset (< 100K customers):** < 1 minute.
- **Medium dataset (100K - 10M customers):** 1-10 minutes (Spectrum I/O dominates).
- **Large dataset (> 10M customers):** 10+ minutes. Consider incremental loading or pre-aggregation.

### Storage Footprint
- **Uncompressed:** ~500 bytes per customer (rough estimate: 15 columns × 30 bytes avg).
- **Compressed (Redshift default):** ~150-200 bytes per customer (3-4x compression typical).
- **Example:** 10M customers ≈ 1.5-2 GB compressed.

---

## Dependencies

### Upstream
| Component | Type | Frequency | Notes |
|-----------|------|-----------|-------|
| **spectrum.raw_customers** | External (S3 CSV via Spectrum) | Daily or near-real-time | CRM export. Must be available before this job runs. If export fails, this job will fail. |

### Downstream
| Component | Type | Dependency | Notes |
|-----------|------|------------|-------|
| **mart.dim_customers** | Table | Reads from `stg_raw_customers` | Customer dimension for fact tables. Runs after this job completes. |
| **mart.fct_customer_activity** | Table | Joins with `stg_raw_customers` on customer_id | Activity fact table. Requires customer master data. |
| **analytics.customer_segmentation** | View | Filters/aggregates `stg_raw_customers` | Cohort analysis, RFM segmentation. Depends on clean customer data. |
| **bi_dashboards.customer_360** | BI Dashboard | Queries `stg_raw_customers` | Executive dashboard. Requires up-to-date customer master. |
| **reports.customer_export** | Report | Exports from `stg_raw_customers` | Regulatory/compliance reports. Depends on PII masking. |

### External Dependencies
| System | Purpose | Risk |
|--------|---------|------|
| **Redshift Spectrum** | Query S3 data | If Spectrum is unavailable or S3 path changes, this job fails. |
| **S3 (CRM export location)** | Source data storage | If S3 bucket is deleted or permissions revoked, this job fails. |
| **Redshift cluster** | Compute & storage | If cluster is paused or resized, this job may fail or run slowly. |

### Permissions & Access Control
```sql
GRANT SELECT ON staging.stg_raw_customers TO GROUP analytics_readers;
```
- **Who can read:** Members of `analytics_readers` group.
- **Who can write:** Only the job owner (typically a service account or data engineer).
- **Audit:** All queries are logged in Redshift audit tables. Monitor for unusual access patterns.

---

## Maintenance & Monitoring

### Key Metrics to Monitor
- **Row count:** Should match expected customer base (e.g., 10M ± 5%). Alert if count drops > 10% (possible data loss).
- **Null rates:** Monitor null rates for key fields (email, customer_id). Alert if nulls exceed threshold (e.g., > 1%).
- **Load time:** Track query runtime. Alert if > 2x baseline (possible performance degradation).
- **Deduplication ratio:** Monitor `COUNT(DISTINCT customer_id) / COUNT(*)`. Should be close to 1.0 (few duplicates). If < 0.95, investigate upstream data quality.

### Refresh Schedule
- **Recommended:** Daily, after CRM export completes (typically early morning).
- **Incremental alternative:** If full refresh is too slow, consider incremental loading:
  ```sql
  DELETE FROM staging.stg_raw_customers WHERE customer_id IN (SELECT id FROM spectrum.raw_customers WHERE updated_at >= GETDATE() - INTERVAL '1 day');
  INSERT INTO staging.stg_raw_customers SELECT ... WHERE updated_at >= GETDATE() - INTERVAL '1 day';
  ```

### Alerting Rules
- **Data quality:** Alert if null rate for `email` or `customer_id` > 5%.
- **Performance:** Alert if query runtime > 15 minutes.
- **Volume:** Alert if row count changes > 20% day-over-day.
- **Deduplication:** Alert if deduplication ratio < 0.95 (many duplicates).

---

## Related Documentation
- **Data Governance:** PII masking policy (link to policy doc).
- **CRM Integration:** Spectrum configuration and S3 path (link to infrastructure docs).
- **Downstream Models:** `mart.dim_customers`, `mart.fct_customer_activity` (link to model docs).
- **Redshift Best Practices:** Distribution keys, sort keys, compression (link to internal wiki).