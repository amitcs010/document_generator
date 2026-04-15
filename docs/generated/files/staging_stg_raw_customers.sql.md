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
| **spectrum.raw_customers** | Raw customer records exported from CRM system (S3 CSV via Redshift Spectrum) | Contains unstructured, potentially duplicate records with PII; updated daily or on-demand from source system |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **staging.stg_raw_customers** | Deduplicated, PII-masked customer master records with standardized types and computed fields | Analytics dashboards, customer segmentation models, reporting views, downstream fact tables (e.g., `fct_customer_transactions`), BI tools (Tableau, Looker) |

---

## Key Business Logic

### 1. **Deduplication by Customer ID**
- **Logic:** `ROW_NUMBER() OVER (PARTITION BY c.id ORDER BY c.updated_at DESC)` ranks all records per customer, keeping only the most recent (`WHERE _row_num = 1`).
- **Why:** CRM exports may contain duplicate records due to ETL reruns, data sync issues, or multiple export batches. Keeping the most recent ensures analytics reflects the latest customer state.
- **Business Impact:** Prevents inflated customer counts and ensures metrics (e.g., active customers, churn) are accurate.

### 2. **PII Masking for Compliance**
- **Email:** Hashed with MD5 and domain extracted separately.
  - **Why:** Enables analytics on email domain trends (e.g., corporate vs. consumer) without exposing raw email addresses; MD5 hash allows linkage to external datasets while protecting privacy.
- **Name:** First and last names truncated to first character + `***`.
  - **Why:** Complies with GDPR/CCPA; allows name-based segmentation without exposing full names.
- **Phone:** Only country prefix (first 3 digits) retained.
  - **Why:** Enables geographic/telecom analysis without exposing full phone numbers.
- **Postal Code:** First 3 characters + `***`.
  - **Why:** Allows regional analysis while obscuring precise location data.

### 3. **Data Type Standardization**
- All fields explicitly cast to target types (BIGINT, VARCHAR, DATE, DECIMAL).
- **Why:** Raw CSV data arrives as strings; explicit casting ensures consistency and prevents downstream type mismatches.
- **Edge Case:** `CONVERT(DATE, c.created_at)` assumes source dates are in a recognizable format; malformed dates will fail or NULL.

### 4. **Null Handling & Defaults**
- **marketing_opt_in:** `NVL(c.marketing_opt_in, FALSE)` defaults to FALSE (opt-out by default for compliance).
- **loyalty_tier:** `NVL(c.loyalty_tier, 'Bronze')` defaults to Bronze tier (conservative assumption for new/unclassified customers).
- **reported_ltv:** `NVL(reported_ltv, 0)` defaults to 0 (no revenue assumed if missing).
- **Why:** Ensures no NULL values propagate downstream, preventing join failures and NULL-related bugs in analytics.

### 5. **Computed Fields**
- **days_since_registration:** `DATEDIFF(day, registration_date, GETDATE())` calculates customer tenure.
  - **Why:** Enables cohort analysis and customer lifecycle segmentation without requiring downstream recalculation.
- **_loaded_at:** `GETDATE()` captures load timestamp for audit trails and incremental refresh logic.
  - **Why:** Enables data lineage tracking and supports SCD (Slowly Changing Dimension) patterns in downstream layers.

### 6. **Input Validation**
- `WHERE c.id IS NOT NULL AND c.email IS NOT NULL AND LEN(c.email) > 3`
- **Why:** Filters out incomplete records that cannot be uniquely identified or contacted; email length > 3 rejects obviously malformed entries (e.g., "a@b").
- **Business Impact:** Ensures only valid customer records enter analytics; prevents downstream join failures on customer_id.

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **customer_id** | BIGINT | Unique customer identifier from CRM; primary key | `12345`, `98765432` |
| **email_hash** | VARCHAR(32) | MD5 hash of lowercased, trimmed email; enables privacy-compliant email analytics | `5d41402abc4b2a76b9719d911017c592` |
| **email_domain** | VARCHAR(256) | Email domain extracted from raw email; enables B2B vs. B2C segmentation | `gmail.com`, `acme.com`, `company.co.uk` |
| **first_name_masked** | VARCHAR(4) | First character of first name + `***`; complies with PII masking | `J***`, `A***` |
| **last_name_masked** | VARCHAR(4) | First character of last name + `***`; complies with PII masking | `S***`, `D***` |
| **phone_country_prefix** | VARCHAR(3) | First 3 digits of phone (country code); enables geographic analysis | `+1`, `+44`, `+33` |
| **country** | VARCHAR(2) | ISO 3166-1 alpha-2 country code | `US`, `GB`, `DE`, `CA` |
| **state** | VARCHAR(50) | State/province name or code | `CA`, `NY`, `ON`, `Bavaria` |
| **city** | VARCHAR(100) | City name | `San Francisco`, `London`, `Toronto` |
| **postal_code_masked** | VARCHAR(6) | First 3 characters of postal code + `***`; enables regional analysis with privacy | `94***`, `SW1***`, `M5***` |
| **registration_date** | DATE | Date customer account was created in CRM | `2023-01-15`, `2024-06-20` |
| **last_login_date** | DATE | Date of most recent customer login | `2024-12-10`, `2024-11-30` |
| **marketing_opt_in** | BOOLEAN | Whether customer consented to marketing communications (defaults to FALSE) | `TRUE`, `FALSE` |
| **loyalty_tier** | VARCHAR(50) | Customer loyalty program tier (defaults to 'Bronze') | `Bronze`, `Silver`, `Gold`, `Platinum` |
| **reported_ltv** | DECIMAL(12,2) | Lifetime value reported by CRM system; may not reflect actual revenue (defaults to 0) | `1250.50`, `0.00`, `45000.00` |
| **days_since_registration** | INT | Number of days between registration and load date; enables tenure-based segmentation | `45`, `365`, `1200` |
| **_loaded_at** | TIMESTAMP | Timestamp when record was loaded into staging; used for audit and incremental logic | `2024-12-15 14:32:00`, `2024-12-15 14:32:01` |

---

## Data Quality & Edge Cases

### Null Handling
| Field | Behavior | Risk |
|-------|----------|------|
| **customer_id** | Filtered out (`WHERE c.id IS NOT NULL`) | None; invalid records excluded |
| **email** | Filtered out if NULL or length ≤ 3 | Valid short emails (e.g., `a@b.co`) rejected; acceptable trade-off |
| **marketing_opt_in** | Defaults to FALSE | Conservative; may undercount opted-in customers if source data is incomplete |
| **loyalty_tier** | Defaults to 'Bronze' | May misclassify new customers; should be validated against CRM tier definitions |
| **reported_ltv** | Defaults to 0 | May understate revenue for customers with missing LTV; consider flagging for manual review |
| **last_login_date** | Allowed to be NULL | Indicates customer has never logged in; valid for new registrations |

### Deduplication Strategy
- **Method:** `ROW_NUMBER()` with `PARTITION BY c.id ORDER BY c.updated_at DESC`
- **Assumption:** `updated_at` timestamp is reliable and monotonically increasing.
- **Risk:** If `updated_at` is not populated or is incorrect, deduplication may retain stale records.
- **Mitigation:** Validate `updated_at` distribution in source data; consider adding a secondary sort key (e.g., `created_at DESC`) if `updated_at` is unreliable.

### Data Type Assumptions
| Field | Assumption | Failure Mode |
|-------|-----------|--------------|
| **id** | Numeric, non-negative | `CAST(c.id AS BIGINT)` fails if source contains non-numeric values (e.g., `"CUST-12345"`) |
| **created_at, last_login** | ISO 8601 or recognizable date format | `CONVERT(DATE, ...)` fails or returns NULL if format is unexpected (e.g., `"12/31/2024"` in non-US locale) |
| **lifetime_value** | Numeric, non-negative | `CAST(c.lifetime_value AS DECIMAL(12,2))` fails if source contains currency symbols or text (e.g., `"$1,250.50"`) |
| **email** | Valid email format | No validation; malformed emails (e.g., `"user@"`, `"@domain.com"`) pass through and hash to valid MD5 |

### Upstream Data Change Risks
| Change | Impact | Mitigation |
|--------|--------|-----------|
| **New PII fields added to source** | Not masked; may violate compliance | Add masking logic proactively; audit schema changes |
| **Email format changes** (e.g., `"user+tag@domain.com"`) | `SPLIT_PART(email_raw, '@', 2)` still works; hash remains consistent | No action needed; logic is robust |
| **Postal code format changes** (e.g., from `"12345"` to `"12345-6789"`) | Masking logic `LEFT(postal_code, 3)` still works; may expose more/less data | Review masking threshold if format changes significantly |
| **Duplicate records increase** (e.g., due to CRM sync bug) | Deduplication still works; no data loss, but may hide upstream issues | Add monitoring alert if duplicate rate exceeds threshold |
| **updated_at becomes NULL or unreliable** | Deduplication may retain arbitrary records | Add fallback sort key or alert on NULL `updated_at` |

---

## Performance Notes

### Distribution & Sort Keys
```sql
DISTKEY(customer_id)
SORTKEY(customer_id)
```
- **DISTKEY(customer_id):** Distributes rows across Redshift nodes by customer_id, ensuring all records for a customer co-locate on the same node.
  - **Why:** Optimizes joins on customer_id in downstream queries (e.g., joining with transactions, orders).
  - **Trade-off:** If customer_id distribution is skewed (e.g., one customer has 10M records), that node becomes a bottleneck.
  - **Mitigation:** Monitor node distribution; consider compound key if skew is detected.

- **SORTKEY(customer_id):** Sorts rows within each node by customer_id, enabling efficient range scans and merge joins.
  - **Why:** Accelerates queries filtering by customer_id range or joining with other customer-keyed tables.
  - **Trade-off:** Slows INSERT/UPDATE operations; acceptable for staging layer (typically loaded once daily).

### Join Strategy
- **CTE (ranked):** Single table scan of `spectrum.raw_customers` with window function.
  - **Cost:** Full table scan + window function computation (O(n log n) due to sort).
  - **Why:** Necessary for deduplication; no way to avoid full scan.
  - **Optimization:** If `spectrum.raw_customers` is very large (>1B rows), consider filtering by date range in the WHERE clause (e.g., `WHERE c.updated_at >= DATEADD(day, -1, GETDATE())`) to reduce scan scope.

### Expensive Operations
| Operation | Cost | Mitigation |
|-----------|------|-----------|
| **MD5 hashing** | O(n) string hashing | Acceptable; MD5 is fast; ~1M rows/sec on modern hardware |
| **SPLIT_PART** | O(n) string parsing | Acceptable; simple operation |
| **DATEDIFF** | O(n) date arithmetic | Negligible; vectorized in Redshift |
| **ROW_NUMBER window function** | O(n log n) due to sort | Unavoidable for deduplication; consider pre-sorting source if possible |

### Estimated Performance
- **Input:** 10M raw customer records (with duplicates)
- **Output:** ~8M deduplicated records (assuming 20% duplication rate)
- **Runtime:** ~30-60 seconds on a 2-node Redshift cluster (dc2.large)
- **Storage:** ~500 MB (assuming ~60 bytes per row)

### Incremental Load Optimization
- **Current:** Full table reload (DROP + CREATE).
- **Recommendation:** Consider incremental approach for large datasets:
  ```sql
  -- Pseudo-code: incremental load
  DELETE FROM staging.stg_raw_customers
  WHERE customer_id IN (SELECT DISTINCT id FROM spectrum.raw_customers WHERE updated_at >= DATEADD(day, -1, GETDATE()));
  
  INSERT INTO staging.stg_raw_customers
  SELECT ... FROM ranked WHERE _row_num = 1 AND updated_at >= DATEADD(day, -1, GETDATE());
  ```
  - **Benefit:** Reduces runtime from 60s to ~10s for daily incremental loads.
  - **Trade-off:** Requires careful handling of deletes and re-inserts; adds complexity.

---

## Dependencies

### Upstream
| Component | Type | Criticality | Notes |
|-----------|------|-------------|-------|
| **spectrum.raw_customers** | External table (S3 CSV via Redshift Spectrum) | **Critical** | Must be refreshed before this job runs; if missing or corrupted, this job fails |
| **Redshift Spectrum configuration** | Infrastructure | **Critical** | S3 bucket, IAM role, and Spectrum external schema must be configured; if misconfigured, table scan fails |

### Downstream
| Component | Type | Dependency Type | Notes |
|-----------|------|-----------------|-------|
| **dim_customers** (dimensional layer) | Table | **Direct** | Consumes `stg_raw_customers` to build customer dimension; must run after this job |
| **fct_customer_transactions** | Table | **Indirect** | Joins with `dim_customers` (which depends on this table); ensures referential integrity |
| **customer_segmentation_model** | ML model | **Indirect** | Uses customer features from this table; retraining depends on data freshness |
| **analytics_dashboards** (Tableau, Looker) | BI reports | **Indirect** | Dashboards query downstream tables that depend on this staging table |
| **customer_360_view** | View | **Direct** | Aggregates customer data from this table for CRM/marketing teams |

### External
| System | Purpose | Notes |
|--------|---------|-------|
| **S3 (CRM export bucket)** | Source data storage | CSV files uploaded daily by CRM system; path and format must be consistent |
| **Redshift Spectrum** | External table layer | Enables querying S3 data without copying to Redshift; requires active Spectrum subscription |
| **analytics_readers IAM group** | Access control | Downstream users must be members to query this table; managed by data governance team |

### Execution Order
```
1. CRM system exports customer data to S3
2. Redshift Spectrum external table (spectrum.raw_customers) points to S3 CSV
3. staging.stg_raw_customers job runs (this component)
4. dim_customers job runs (depends on step 3)
5. Downstream fact tables and dashboards refresh (depend on step 4)
```

---

## Maintenance & Monitoring

### Recommended Alerts
- **Duplicate rate > 25%:** Indicates upstream data quality issue; investigate CRM sync.
- **NULL customer_id rate > 5%:** Indicates upstream data corruption; investigate source.
- **Load time > 2x baseline:** Indicates performance degradation; check Redshift cluster health or data volume growth.
- **Email hash collisions:** Monitor for MD5 collisions (unlikely but possible); consider SHA-256 if needed.

### Testing Checklist
- [ ] Verify deduplication: `SELECT customer_id, COUNT(*) FROM stg_raw_customers GROUP BY customer_id HAVING COUNT(*) > 1` should return 0 rows.
- [ ] Verify PII masking: Spot-check that no full emails, phone numbers, or postal codes appear in output.
- [ ] Verify data types: `SELECT * FROM stg_raw_customers LIMIT 1` and confirm all columns match expected types.
- [ ] Verify referential integrity: All `customer_id` values are non-NULL and unique.
- [ ] Verify date ranges: `registration_date` and `last_login_date` should be within reasonable bounds (e.g., not in future).