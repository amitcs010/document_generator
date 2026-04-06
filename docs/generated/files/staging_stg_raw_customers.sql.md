# staging/stg_raw_customers.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; infer from orchestration metadata
- **Owner:** Not specified in code; infer from data governance system

---

## Purpose

This component ingests raw customer records from the CRM export (stored in S3 via Redshift Spectrum) and prepares them for downstream analytics and reporting. It deduplicates customer records, applies PII masking to comply with privacy regulations, and enriches the data with derived fields (e.g., days since registration). The output serves as the single source of truth for customer identity and attributes across the analytics layer, enabling secure access by analytics teams while protecting sensitive personal information.

---

## Inputs

| Source | Purpose | Notes |
|--------|---------|-------|
| **spectrum.raw_customers** | Raw customer records exported from the CRM system (S3-backed Redshift Spectrum table). Provides all customer attributes including contact info, registration dates, and loyalty data. | CSV export; may contain duplicates due to CRM sync issues or multiple updates within the same batch window. No SLA on freshness specified. |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **staging.stg_raw_customers** | Deduplicated, PII-masked customer records with derived temporal fields. One row per unique customer_id. ~15 columns including hashed email, masked names/phone, location, registration metadata, and loyalty tier. | `mart_customers` (dimensional model), `fct_customer_events` (fact tables), BI dashboards, customer segmentation models, marketing analytics. Read access granted to `analytics_readers` group. |

---

## Key Business Logic

### 1. **Deduplication by Most Recent Update**
```
ROW_NUMBER() OVER (PARTITION BY c.id ORDER BY c.updated_at DESC)
```
- **Why:** CRM exports may contain multiple rows per customer due to batch reprocessing or sync delays. The business rule is to keep the most recent record (by `updated_at` timestamp).
- **Impact:** If a customer record is updated multiple times in a single batch, only the latest version is retained. This assumes `updated_at` is reliable and monotonically increasing.
- **Risk:** If `updated_at` is not populated or is incorrect, deduplication may fail silently, leading to stale data downstream.

### 2. **PII Masking for Compliance**
Three masking strategies are applied:

| Field | Strategy | Business Reason |
|-------|----------|-----------------|
| **email** | MD5 hash of lowercased, trimmed email + extraction of domain | Enables email-based joins and domain-level analytics (e.g., corporate vs. consumer) without exposing full email addresses. Hash is deterministic for record linkage. |
| **first_name / last_name** | Keep first character + mask remainder (e.g., "John" → "J***") | Allows name-based reporting and segmentation without exposing full PII. Complies with GDPR/CCPA requirements for analytics use cases. |
| **phone** | Extract country prefix (first 3 digits) only | Enables geographic/telecom analysis without exposing full phone numbers. |
| **postal_code** | Keep first 3 characters + mask remainder | Preserves geographic granularity (e.g., ZIP code prefix for regional analysis) while masking precise location. |

- **Assumption:** Downstream consumers do not need full PII; they only need aggregated or anonymized attributes for analytics.
- **Risk:** If a downstream use case requires full email or phone for customer service, this table cannot support it; a separate, access-controlled PII table would be needed.

### 3. **Null Handling & Defaults**
```sql
NVL(c.marketing_opt_in, FALSE)     -- Default to FALSE (opt-out by default)
NVL(c.loyalty_tier, 'Bronze')      -- Default to Bronze tier
NVL(reported_ltv, 0)               -- Default LTV to 0
```
- **Why:** Ensures no null values propagate downstream, which could break joins or aggregations. Defaults reflect business policy: assume customers are not opted in for marketing unless explicitly flagged, and assume base loyalty tier if not specified.
- **Risk:** If a null value has semantic meaning (e.g., "loyalty tier unknown"), this logic conflates missing data with a business default, potentially skewing segmentation.

### 4. **Data Validation Filters**
```sql
WHERE c.id IS NOT NULL
  AND c.email IS NOT NULL
  AND LEN(c.email) > 3
```
- **Why:** Excludes invalid records that cannot be uniquely identified or contacted. Email length > 3 is a basic sanity check (e.g., "a@b" is invalid).
- **Impact:** Silently drops records with missing ID or email. No logging of rejected records.
- **Risk:** If a valid customer has a malformed email in the source system, they are excluded from analytics without visibility. Consider adding a `_rejected_reason` column for audit trails.

### 5. **Derived Temporal Field**
```sql
DATEDIFF(day, registration_date, GETDATE()) AS days_since_registration
```
- **Why:** Enables cohort analysis and customer lifecycle segmentation (e.g., "customers registered in last 30 days").
- **Impact:** This field is recalculated on every load, so historical cohorts will shift. For stable cohort analysis, consider storing the registration cohort as a fixed attribute.

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **customer_id** | BIGINT | Unique customer identifier from CRM. Primary key. | 12345, 67890 |
| **email_hash** | VARCHAR(32) | MD5 hash of lowercased, trimmed email. Used for joins and deduplication without exposing PII. | `5d41402abc4b2a76b9719d911017c592` |
| **email_domain** | VARCHAR(256) | Domain portion of email address. Enables B2B vs. B2C segmentation and corporate email analysis. | `gmail.com`, `acme.com`, `company.co.uk` |
| **first_name_masked** | VARCHAR(4) | First character of first name + mask. Preserves minimal identity info for reporting. | `J***`, `S***` |
| **last_name_masked** | VARCHAR(4) | First character of last name + mask. | `D***`, `S***` |
| **phone_country_prefix** | VARCHAR(3) | First 3 digits of phone number (country code). Enables geographic analysis. | `+1`, `+44`, `+33` |
| **country** | VARCHAR(2) | ISO 3166-1 alpha-2 country code. | `US`, `GB`, `CA` |
| **state** | VARCHAR(50) | State or province. | `CA`, `NY`, `ON` |
| **city** | VARCHAR(100) | City name. | `San Francisco`, `Toronto` |
| **postal_code_masked** | VARCHAR(6) | First 3 characters of postal code + mask. Preserves regional granularity. | `94***`, `M5***` |
| **registration_date** | DATE | Date customer first registered in CRM. Used for cohort analysis. | `2023-01-15`, `2024-06-20` |
| **last_login_date** | DATE | Date of most recent login. Indicates engagement level. | `2024-01-10`, NULL (if never logged in) |
| **marketing_opt_in** | BOOLEAN | Whether customer has opted in to marketing communications. Defaults to FALSE. | TRUE, FALSE |
| **loyalty_tier** | VARCHAR(50) | Customer loyalty program tier. Defaults to 'Bronze' if not specified. | `Bronze`, `Silver`, `Gold`, `Platinum` |
| **reported_ltv** | DECIMAL(12,2) | Lifetime value reported by CRM. Defaults to 0. May be stale or inaccurate; consider recalculating from transactions. | `1250.50`, `0.00` |
| **days_since_registration** | INT | Number of days between registration and load date. Recalculated on each load. | `45`, `365` |
| **_loaded_at** | TIMESTAMP | Timestamp when this record was loaded into the staging table. Used for audit trails and incremental load logic. | `2024-01-20 14:30:00` |

---

## Data Quality & Edge Cases

### Null Handling
| Field | Null Behavior | Risk |
|-------|---------------|------|
| **customer_id** | Filtered out (WHERE c.id IS NOT NULL) | Valid customers with missing IDs are silently dropped. No audit trail. |
| **email** | Filtered out (WHERE c.email IS NOT NULL AND LEN(c.email) > 3) | Customers without email are excluded; may miss valid records with alternative contact methods. |
| **marketing_opt_in** | Defaults to FALSE | Assumes opt-out by default; if source system uses NULL to mean "unknown," this conflates unknown with opted-out. |
| **loyalty_tier** | Defaults to 'Bronze' | If NULL means "not enrolled," this incorrectly assigns a tier. Consider using a distinct 'Unknown' value. |
| **reported_ltv** | Defaults to 0 | Conflates "no value" with "zero value." New customers with NULL LTV are treated identically to customers with $0 LTV. |
| **last_login_date** | Allowed to be NULL | Correctly represents customers who have never logged in. No masking applied. |

### Deduplication Strategy
- **Method:** ROW_NUMBER() partitioned by customer_id, ordered by updated_at DESC.
- **Assumption:** `updated_at` is always populated and monotonically increasing within a customer's record history.
- **Edge Case:** If two records have the same `updated_at` timestamp, the order is non-deterministic (depends on Redshift's internal sort order). Consider adding a tiebreaker (e.g., `ORDER BY updated_at DESC, id DESC`).
- **Visibility:** Deduplicated records are silently dropped. No `_dedup_count` or `_rejected_reason` column to track how many duplicates were removed per load.

### Data Validation Assumptions
1. **Email Format:** Code assumes email is in `local@domain` format and uses `SPLIT_PART(email_raw, '@', 2)` to extract domain. If email contains multiple `@` symbols (invalid but possible), this will extract only the first domain portion.
2. **Phone Format:** Assumes phone numbers start with a country code in the first 3 characters. If phone is stored as `(123) 456-7890` or `123-456-7890`, the country prefix extraction will fail or return incorrect values.
3. **Postal Code:** Assumes postal codes are at least 3 characters. If a postal code is shorter (e.g., `AB`), `LEFT(postal_code, 3)` will return the entire code unmasked.
4. **Date Formats:** Uses `CONVERT(DATE, ...)` which assumes source dates are in a format Redshift can parse. If dates are stored as strings in an unexpected format, conversion will fail.

### Potential Data Quality Issues
- **Stale LTV:** `reported_ltv` is sourced from CRM and may not reflect actual customer spend. Consider recalculating from transaction data in a downstream mart.
- **Inconsistent Country Codes:** `country` field may contain full country names, ISO 2-letter codes, or ISO 3-letter codes. No validation is applied.
- **Missing Location Data:** If a customer has no address, `state`, `city`, and `postal_code` will be NULL, and masking will fail (e.g., `LEFT(NULL, 3)` returns NULL, not a masked value).
- **Email Domain Extraction:** If `email_raw` is malformed (e.g., missing `@`), `SPLIT_PART` will return the entire email or NULL, breaking downstream joins on `email_domain`.

---

## Performance Notes

### Distribution & Sort Keys
```sql
DISTKEY(customer_id)
SORTKEY(customer_id)
```
- **Rationale:** 
  - `DISTKEY(customer_id)` ensures all records for a given customer are co-located on the same node, enabling efficient joins on `customer_id` in downstream tables (e.g., `fct_customer_events`).
  - `SORTKEY(customer_id)` enables fast range scans and joins on the primary key.
- **Trade-off:** If downstream queries frequently filter by `country` or `registration_date`, a compound sort key (e.g., `SORTKEY(country, registration_date, customer_id)`) might be more efficient. Current choice optimizes for customer-centric joins.

### Join Strategy in CTE
```sql
FROM spectrum.raw_customers c
WHERE c.id IS NOT NULL ...
```
- **Type:** Full table scan of Spectrum table (external S3 data).
- **Cost:** Spectrum queries are slower than native Redshift tables because data is read from S3 on each query. No statistics or indexes on Spectrum tables.
- **Optimization:** If `spectrum.raw_customers` is large (>1B rows), consider materializing it as a native Redshift table first, then staging from that.

### Window Function
```sql
ROW_NUMBER() OVER (PARTITION BY c.id ORDER BY c.updated_at DESC)
```
- **Cost:** Requires sorting all records by `id` and `updated_at`. For large customer bases (millions of records), this can be expensive.
- **Optimization:** If deduplication is the bottleneck, consider using a more efficient method:
  ```sql
  SELECT DISTINCT ON (c.id) ... FROM spectrum.raw_customers c ORDER BY c.id, c.updated_at DESC
  ```
  (if Redshift supports DISTINCT ON; otherwise, use a subquery with MAX(updated_at) per id).

### Table Size & Refresh Frequency
- **Estimated Size:** If 10M customers × 15 columns × ~200 bytes per row ≈ 30 GB (uncompressed). Redshift compression typically achieves 3-5x, so ~6-10 GB on disk.
- **Refresh Strategy:** Full table drop and recreate (`DROP TABLE IF EXISTS`). No incremental loading. For large tables, consider switching to incremental inserts or upserts to reduce load time.
- **Refresh Time:** Depends on Spectrum read speed and deduplication cost. Estimate 5-15 minutes for 10M customers.

### ANALYZE Statement
```sql
ANALYZE staging.stg_raw_customers;
```
- **Purpose:** Updates table statistics (row count, column distributions) used by the query optimizer.
- **Impact:** Improves downstream query performance by enabling better join and filter selectivity estimates.
- **Cost:** Scans the entire table; adds ~1-2 minutes to load time.

---

## Dependencies

### Upstream
| Component | Type | Frequency | Notes |
|-----------|------|-----------|-------|
| **spectrum.raw_customers** | External S3 CSV (via Redshift Spectrum) | Daily (assumed) | CRM export. No SLA specified. If this export fails or is delayed, staging load will fail or produce stale data. |
| **Redshift Cluster** | Infrastructure | Always-on | Requires active Redshift cluster with Spectrum enabled. |

### Downstream
| Component | Type | Dependency Type | Notes |
|-----------|------|-----------------|-------|
| **mart_customers** | Dimensional table | Direct read | Joins on `customer_id` to enrich customer attributes. Must run after this staging table is refreshed. |
| **fct_customer_events** | Fact table | Direct read | Joins on `customer_id` to add customer context to events. Requires `email_hash` for deduplication. |
| **analytics_readers** | IAM Group | Access control | SELECT permission granted to this group. Any user in this group can query the table. |
| **BI Dashboards** (Tableau, Looker, etc.) | BI Tools | Indirect read | Dashboards query `mart_customers` or other downstream tables that depend on this staging table. |
| **Customer Segmentation Models** | ML/Analytics | Direct read | May use `loyalty_tier`, `days_since_registration`, `reported_ltv` for clustering or classification. |

### External
| System | Purpose | Notes |
|--------|---------|-------|
| **CRM (source system)** | Provides raw customer data | Export schedule and data quality are outside the control of this component. |
| **S3 (data lake)** | Stores raw CSV files | Spectrum reads from S3; ensure S3 bucket permissions and network connectivity are configured. |
| **Redshift IAM Role** | Authorizes S3 access | Must have `s3:GetObject` permission on the S3 bucket containing raw_customers CSV. |

---

## Additional Considerations

### Security & Compliance
- **PII Masking:** Email, name, phone, and postal code are masked. However, `country`, `state`, and `city` remain unmasked and could be combined to re-identify individuals. Consider additional masking if GDPR/CCPA requires stricter controls.
- **Access Control:** `GRANT SELECT ON staging.stg_raw_customers TO GROUP analytics_readers;` restricts read access to the `analytics_readers` group. Ensure this group's membership is audited regularly.
- **Audit Trail:** No `_created_by`, `_updated_by`, or `_change_reason` columns. Consider adding these for compliance and debugging.

### Maintenance & Monitoring
- **Alerting:** No error handling or logging. If the load fails (e.g., Spectrum table missing, email parsing error), there is no notification. Recommend adding try-catch logic and alerting to orchestration tool.
- **Data Freshness:** `_loaded_at` timestamp enables freshness monitoring. Set up alerts if `_loaded_at` is older than expected (e.g., > 24 hours).
- **Duplicate Detection:** No metrics on how many records were deduplicated per load. Consider adding a `_dedup_count` column or logging to a metadata table for visibility.

### Testing Recommendations
1. **Null Handling:** Test with records where email, phone, postal_code are NULL or empty strings.
2. **Deduplication:** Test with multiple records per customer_id with different `updated_at` timestamps; verify only the most recent is retained.
3. **PII Masking:** Verify that masked values are consistent (e.g., same email always hashes to the same value) and that no full PII leaks into output columns.
4. **Edge Cases:** Test with emails containing multiple `@` symbols, phone numbers in non-standard formats, and postal codes shorter than 3 characters.
5. **Performance:** Load test with 10M+ customer records to ensure refresh time is acceptable.