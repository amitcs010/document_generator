# staging/stg_raw_orders.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (materialized)
- **Schedule:** Daily at 02:00 UTC
- **Owner:** Data Engineering
- **SLA:** Must complete before 06:00 UTC (assumed; check with analytics team)

---

## Purpose

This component ingests raw order transaction data from S3-backed Spectrum external tables into Redshift, applying standardized type casting, basic data cleaning, and business rule filtering. It serves as the single source of truth for order data across the analytics platform, removing test/system-cancelled orders and ensuring consistent data types for downstream reporting and modeling. Analytics teams, BI tools, and data scientists consume this table to build dashboards, reports, and predictive models.

---

## Inputs

| Source | Purpose | Notes |
|--------|---------|-------|
| **spectrum.raw_orders** | Raw order transaction records from S3 parquet files | Federated query via Redshift Spectrum; contains unvalidated, mixed-type data from the operational system |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **staging.stg_raw_orders** | Cleaned, type-cast order records with 3-day rolling window | `mart_orders`, `fct_orders`, BI dashboards (Tableau/Looker), ad-hoc analytics queries, ML feature engineering |

---

## Key Business Logic

### 1. **Rolling 3-Day Window Filter**
```sql
WHERE o.created_at >= DATEADD(day, -3, GETDATE())
```
- **Why:** Reduces table size and query latency by retaining only recent orders (last 72 hours). Assumes downstream processes handle historical data separately or via incremental loads.
- **Risk:** If daily job fails for >3 days, historical orders may be lost. Recommend archival strategy or longer retention window.

### 2. **Test Order Exclusion**
```sql
AND o.is_test = FALSE
```
- **Why:** Prevents test/QA orders from polluting analytics and skewing business metrics (revenue, conversion rates, customer counts).
- **Assumption:** Source system reliably flags test orders; if this flag is unreliable, metrics will be inaccurate.

### 3. **System-Cancelled Order Exclusion**
```sql
AND o.status != 'cancelled_by_system'
```
- **Why:** System-cancelled orders (e.g., payment failures, inventory issues) represent failed transactions and should not be counted as revenue or customer activity.
- **Note:** User-initiated cancellations are retained; only automated cancellations are filtered.

### 4. **Positive Amount Filter**
```sql
AND o.total_amount > 0
```
- **Why:** Excludes zero-value or negative orders (refunds, adjustments, data errors). Ensures revenue metrics are accurate.
- **Risk:** Refunds may have negative amounts; if refund logic requires separate handling, this filter may need refinement.

### 5. **Null Handling for Optional Fields**
```sql
NVL(o.coupon_code, 'NONE')     AS coupon_code,
NVL(o.channel, 'web')          AS order_channel,
```
- **Why:** Replaces NULLs with sensible defaults to avoid NULL propagation in downstream joins and aggregations.
- **Assumption:** Missing coupon codes mean no coupon was used; missing channels default to web (likely the primary channel).

### 6. **Type Standardization**
- **IDs (order_id, customer_id):** Cast to BIGINT to ensure consistent join keys and prevent overflow.
- **Amounts (total, discount, tax, shipping):** Cast to DECIMAL(12,2) for financial accuracy (prevents floating-point rounding errors).
- **Codes/Categories (status, country, method):** Cast to VARCHAR with explicit lengths for consistency and storage efficiency.
- **Timestamps:** Converted to explicit DATE and TIMESTAMP types to avoid ambiguous string parsing.

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **order_id** | BIGINT | Unique order identifier; primary key | 1001, 1002, 1003 |
| **customer_id** | BIGINT | Foreign key to customer dimension; used for customer-level aggregations | 501, 502, 503 |
| **order_number** | VARCHAR(50) | Human-readable order reference (e.g., for customer service) | "ORD-2024-001234", "PO-98765" |
| **order_status** | VARCHAR(20) | Current order fulfillment status | "pending", "processing", "shipped", "delivered", "returned" |
| **order_date** | DATE | Date order was created (truncated to midnight UTC) | 2024-01-15, 2024-01-16 |
| **order_timestamp** | TIMESTAMP | Precise timestamp of order creation (includes time) | 2024-01-15 14:32:45, 2024-01-16 09:12:00 |
| **updated_at** | TIMESTAMP | Last modification timestamp (used to detect recent changes) | 2024-01-15 16:00:00 |
| **total_amount** | DECIMAL(12,2) | Total order value including tax and shipping, after discounts | 99.99, 1250.50, 0.01 |
| **discount_amount** | DECIMAL(12,2) | Total discounts applied (coupon + promotional) | 10.00, 25.50, 0.00 |
| **tax_amount** | DECIMAL(12,2) | Sales tax or VAT charged | 8.50, 0.00 (tax-exempt), 125.00 |
| **coupon_code** | VARCHAR(50) | Promotional code used; "NONE" if no coupon | "SUMMER20", "WELCOME10", "NONE" |
| **payment_method** | VARCHAR(30) | How customer paid | "credit_card", "paypal", "apple_pay", "bank_transfer" |
| **billing_country** | VARCHAR(2) | ISO 3166-1 alpha-2 country code for billing address | "US", "GB", "CA", "DE" |
| **order_channel** | VARCHAR(30) | Sales channel; defaults to "web" if missing | "web", "mobile_app", "in_store", "phone" |
| **_loaded_at** | TIMESTAMP | ETL load timestamp (audit column); when this record was inserted | 2024-01-16 02:15:30 |

---

## Data Quality & Edge Cases

### Null Handling
- **coupon_code, order_channel:** Replaced with defaults ("NONE", "web") to avoid NULL propagation.
- **Other columns:** NULLs are preserved; downstream models must handle them explicitly.
  - **Risk:** If `customer_id`, `order_date`, or `total_amount` are NULL, joins and aggregations will fail silently or produce incorrect results.
  - **Recommendation:** Add explicit NULL checks in validation layer or add NOT NULL constraints if source data guarantees non-nullability.

### Deduplication Strategy
- **None applied.** Assumes `spectrum.raw_orders` contains unique records per order ID.
- **Risk:** If source system produces duplicate rows (e.g., due to ETL reprocessing), this table will contain duplicates.
- **Mitigation:** Add `ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY updated_at DESC)` to deduplicate if needed.

### Key Assumptions About Source Data
1. **order_id is unique** — No validation; if duplicates exist upstream, they propagate downstream.
2. **created_at and updated_at are valid timestamps** — CONVERT() will fail if format is unexpected.
3. **is_test flag is reliable** — If source system doesn't properly flag test orders, they will be included.
4. **total_amount > 0 means valid order** — Refunds or adjustments with negative amounts are excluded; may need separate handling.
5. **Country codes are ISO 3166-1 alpha-2** — No validation; invalid codes will be stored as-is.
6. **Spectrum table is always available** — If S3 files are missing or corrupted, query fails.

### What Could Break
| Scenario | Impact | Mitigation |
|----------|--------|-----------|
| Source system changes `created_at` format (e.g., from ISO 8601 to Unix timestamp) | CONVERT() fails; job aborts | Add error handling; validate format in source system |
| S3 parquet files are corrupted or deleted | Spectrum query fails; no data loaded | Implement S3 versioning; add retry logic |
| `is_test` flag stops being populated | Test orders leak into analytics | Add data quality checks; alert on unexpected NULL values |
| Upstream system produces duplicate order_ids | Duplicates in staging table | Add deduplication logic; implement uniqueness constraint |
| `total_amount` becomes negative for refunds | Refunds excluded by `> 0` filter | Separate refund handling; create refund fact table |
| 3-day rolling window causes data loss if job fails | Historical orders lost | Extend window or implement full-load fallback |

---

## Performance Notes

### Distribution & Sort Keys
```sql
DISTKEY(order_id)
SORTKEY(order_date)
```

- **DISTKEY(order_id):** Distributes rows across cluster nodes by order ID. Optimizes joins on `order_id` (e.g., joining with order line items or customer data) by co-locating related rows on the same node. Reduces network traffic.
- **SORTKEY(order_date):** Sorts rows by order date within each node. Accelerates range queries (e.g., "orders in last 30 days") and time-series aggregations. Enables zone map pruning.
- **Trade-off:** DISTKEY and SORTKEY are different columns, which is acceptable; order_date range queries will still benefit from sort order.

### Join Implications
- **Downstream joins on order_id:** Efficient (co-located by DISTKEY).
- **Downstream joins on customer_id:** Less efficient; requires redistribution unless customer dimension is also distributed by customer_id.
- **Recommendation:** Ensure `dim_customers` is also DISTKEY(customer_id) for optimal join performance.

### Expensive Operations
- **CONVERT(DATE, ...) and CONVERT(TIMESTAMP, ...):** Relatively cheap; applied to each row but no aggregation.
- **NVL() function:** Negligible cost.
- **Filtering (WHERE clause):** Spectrum queries can push predicates to S3, reducing data scanned. The 3-day window filter is efficient if S3 files are partitioned by date.
- **DROP TABLE IF EXISTS:** Drops and recreates table daily; no incremental load. Full refresh means:
  - **Pro:** Simple, no merge logic needed.
  - **Con:** Loses intra-day updates if job runs once daily; if source system updates orders after 02:00 UTC, changes won't appear until next day.

### Table Size & Scan Implications
- **3-day rolling window:** Typically 50K–500K rows (depends on order volume). Small enough for full table scans in most queries.
- **ANALYZE:** Runs after table creation to update table statistics; helps query planner optimize downstream queries.

### Potential Bottlenecks
1. **Spectrum query latency:** Reading from S3 is slower than local Redshift tables. If S3 files are not partitioned by date, full scan of raw_orders may be slow.
2. **Type conversion overhead:** CONVERT() on every row; negligible but adds ~5–10% to query time.
3. **Network I/O:** If downstream queries join this table with large dimension tables, network traffic could be high.

---

## Dependencies

### Upstream (Must Run Before This Component)
| Component | Reason | SLA |
|-----------|--------|-----|
| **S3 data ingestion pipeline** | Raw order data must be written to S3 parquet files before Spectrum can query it | Must complete by 01:30 UTC (30-min buffer before this job) |
| **Spectrum external table creation** (`spectrum.raw_orders`) | Spectrum table must exist and be accessible | One-time setup; no ongoing dependency |

### Downstream (Depends on This Component's Output)
| Component | Dependency | Usage |
|-----------|-----------|-------|
| **mart_orders** | Reads from `stg_raw_orders` | Builds order dimension and fact tables for BI |
| **fct_orders** | Reads from `stg_raw_orders` | Fact table for order-level metrics (revenue, AOV, etc.) |
| **dim_customers** (if customer-centric) | May join with `stg_raw_orders` | Enriches customer dimension with order frequency, lifetime value |
| **BI dashboards** (Tableau, Looker) | Direct queries or via marts | Real-time order metrics, sales tracking |
| **ML feature engineering** | Reads for training data | Customer segmentation, churn prediction, recommendation models |
| **Data quality monitoring** | Validates row counts, nulls, duplicates | Alerts if data quality degrades |

### External Dependencies
| System | Purpose | Risk |
|--------|---------|------|
| **AWS S3** | Storage for raw parquet files | If S3 is unavailable or files are deleted, job fails |
| **Redshift Spectrum** | Federated query engine | If Spectrum service is degraded, queries slow or fail |
| **Redshift cluster** | Compute and storage | If cluster is paused or down, job cannot run |
| **IAM roles/permissions** | Access to S3 and Spectrum | If permissions are revoked, job fails with access denied |

---

## Maintenance & Operational Notes

### Monitoring
- **Job duration:** Should complete in <5 minutes (typical for 3-day window). Alert if >15 minutes.
- **Row count:** Validate daily row count is within expected range (e.g., 10K–100K). Alert if 0 or >1M.
- **NULL counts:** Monitor for unexpected NULLs in key columns (order_id, customer_id, total_amount).
- **Duplicate order_ids:** Run periodic checks; if found, investigate source system.

### Troubleshooting
- **Job fails with "table not found":** Spectrum table may not exist or S3 path is wrong. Verify S3 location and Spectrum table definition.
- **Job fails with "permission denied":** Check IAM role has S3 read access and Spectrum permissions.
- **Slow query:** Check if S3 files are partitioned by date; if not, consider repartitioning.
- **Missing recent orders:** Verify source system is writing to S3 on schedule; check S3 file timestamps.

### Future Improvements
1. **Incremental load:** Replace full refresh with incremental merge (INSERT/UPDATE) to capture intra-day changes.
2. **Deduplication:** Add explicit deduplication logic if source system produces duplicates.
3. **Data validation:** Add checks for NULL counts, duplicate order_ids, and amount ranges.
4. **Refund handling:** Create separate refund fact table for negative amounts.
5. **Longer retention:** Extend rolling window beyond 3 days or implement archival strategy.