# staging/stg_raw_orders.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (materialized)
- **Schedule:** Daily at 02:00 UTC
- **Owner:** Data Engineering
- **Refresh Strategy:** Full rebuild (DROP and CREATE)

## Purpose

This component ingests raw order data from S3-backed Spectrum external tables into Redshift, standardizing data types and applying foundational quality filters. It serves as the single source of truth for order data across the analytics platform, removing test orders and system-cancelled transactions while preserving a rolling 3-day window for incremental downstream processing. Downstream analytics, BI dashboards, and financial reporting depend on this cleaned, consistently-typed dataset.

## Inputs

- **spectrum.raw_orders** — External table reading parquet files from S3. Provides raw order records including customer references, financial amounts (total, discount, shipping, tax), payment/shipping methods, geographic data, and order lifecycle metadata. This component requires it because it is the authoritative source of order transactions from the operational system.

## Outputs

- **staging.stg_raw_orders** — Cleaned, type-standardized order table with 17 columns. Consumed by:
  - `marts.fct_orders` (fact table for financial reporting)
  - `marts.dim_orders` (dimension table for order attributes)
  - Ad-hoc analytics queries from `analytics_readers` group
  - Revenue reconciliation and order fulfillment workflows

## Key Business Logic

### Type Standardization
All numeric identifiers (`id`, `customer_id`) are cast to `BIGINT` to prevent overflow and ensure consistent join keys across the warehouse. Order numbers are standardized to `VARCHAR(50)` to accommodate alphanumeric formats from different sales channels.

### Financial Amount Precision
All monetary columns (`total_amount`, `discount_amount`, `shipping_amount`, `tax_amount`) are cast to `DECIMAL(12,2)` to preserve cents-level precision required for financial reconciliation and tax reporting. This prevents floating-point rounding errors that could compound in aggregations.

### Timestamp Normalization
Raw `created_at` and `updated_at` fields are converted to explicit `TIMESTAMP` types to eliminate ambiguity in timezone handling. A separate `order_date` (DATE type) is derived for efficient date-based filtering and grouping in downstream queries.

### Default Value Imputation
- **coupon_code:** Missing values are replaced with `'NONE'` rather than NULL to simplify downstream GROUP BY operations and prevent null-related aggregation surprises.
- **order_channel:** Defaults to `'web'` for missing values, reflecting the dominant channel and avoiding null-related filtering issues in channel-based reports.

### Data Quality Filtering
Three exclusion rules encode business logic:
1. **Rolling 3-day window** (`created_at >= DATEADD(day, -3, GETDATE())`): Limits scope to recent orders, reducing table size and enabling incremental processing patterns. Assumes upstream systems provide at least 3 days of historical data.
2. **Test order exclusion** (`is_test = FALSE`): Removes internal QA/development orders that would skew revenue metrics and customer counts.
3. **System cancellations** (`status != 'cancelled_by_system'`): Filters out orders cancelled by automated processes (e.g., payment failures, fraud blocks) to focus on customer-initiated transactions and valid business events.
4. **Positive amounts** (`total_amount > 0`): Excludes refunds, credits, and data anomalies; assumes all valid orders have positive totals.

### Audit Trail
The `_loaded_at` column (set to `GETDATE()`) records when each row was ingested, enabling data freshness monitoring and debugging of stale data issues.

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **order_id** | BIGINT | Unique order identifier from source system. Primary key for joins to order-level facts. | `1001`, `1002`, `1003` |
| **customer_id** | BIGINT | Foreign key to customer dimension. Used to aggregate orders by customer and calculate lifetime value. | `501`, `502`, `503` |
| **order_number** | VARCHAR(50) | Human-readable order reference, often used in customer communications and support tickets. May include prefixes (e.g., `ORD-2024-001`). | `ORD-2024-001`, `AMZ-5678` |
| **order_status** | VARCHAR(20) | Current fulfillment state of the order. Used to segment orders by lifecycle stage (pending, shipped, delivered, etc.). | `pending`, `shipped`, `delivered`, `returned` |
| **order_date** | DATE | Date portion of order creation, used for time-series analysis and daily reporting. Derived from `created_at`. | `2024-01-15`, `2024-01-16` |
| **order_timestamp** | TIMESTAMP | Full timestamp of order creation with time-of-day precision. Enables intra-day analysis and event sequencing. | `2024-01-15 14:32:45`, `2024-01-15 09:15:22` |
| **updated_at** | TIMESTAMP | Last modification timestamp. Indicates when order status or details last changed; used to detect stale records. | `2024-01-16 08:00:00` |
| **total_amount** | DECIMAL(12,2) | Final order value including all fees and taxes. Primary metric for revenue reporting and order-level profitability. | `99.99`, `1250.50`, `0.01` |
| **discount_amount** | DECIMAL(12,2) | Total discounts applied (promotions, loyalty, etc.). Used to calculate net revenue and discount effectiveness. | `0.00`, `10.00`, `25.50` |
| **shipping_amount** | DECIMAL(12,2) | Shipping/fulfillment cost charged to customer. Used to calculate contribution margin and shipping profitability. | `0.00`, `5.99`, `15.00` |
| **tax_amount** | DECIMAL(12,2) | Sales tax collected. Required for tax compliance reporting and net revenue calculations. | `0.00`, `7.50`, `89.99` |
| **coupon_code** | VARCHAR(50) | Promotion code applied to order, or `'NONE'` if no coupon. Used to measure campaign effectiveness and customer acquisition source. | `NONE`, `SUMMER20`, `WELCOME10` |
| **payment_method** | VARCHAR(30) | How customer paid (credit card, PayPal, etc.). Used for payment processing reconciliation and fraud analysis. | `credit_card`, `paypal`, `apple_pay` |
| **billing_country** | VARCHAR(2) | ISO 3166-1 alpha-2 country code of billing address. Used for tax jurisdiction and regional reporting. | `US`, `CA`, `GB`, `DE` |
| **order_channel** | VARCHAR(30) | Sales channel (web, mobile, marketplace, etc.), defaults to `'web'`. Used to segment revenue by channel and optimize marketing spend. | `web`, `mobile`, `amazon`, `shopify` |
| **_loaded_at** | TIMESTAMP | Warehouse load timestamp. Used to identify data freshness and debug late-arriving records. | `2024-01-16 02:15:30` |

## Data Quality & Edge Cases

### Null Handling Strategy
- **coupon_code** and **order_channel** are explicitly imputed with defaults (`'NONE'` and `'web'`) rather than preserved as NULL. This prevents downstream queries from accidentally filtering out these rows in `WHERE coupon_code IS NOT NULL` conditions.
- **All other columns** preserve NULL values from the source. If `payment_method`, `shipping_method`, or geographic fields are NULL in the source, they remain NULL here. Downstream consumers must handle these gracefully.

### Deduplication
**No explicit deduplication is performed.** The code assumes `spectrum.raw_orders` provides unique rows per order ID. If the source table contains duplicates (e.g., due to failed ETL reruns), this component will propagate them. **Risk:** If upstream Spectrum table is rebuilt with duplicate rows, this table will silently contain duplicates.

### Key Assumptions About Upstream Data
1. **Order IDs are globally unique** across all time periods and channels.
2. **Timestamps are in UTC** or consistently in a single timezone; no timezone conversion is applied.
3. **Financial amounts are already in a single currency** (assumed USD); no currency conversion is performed.
4. **The `is_test` flag is reliable** and accurately marks QA/development orders.
5. **The 3-day rolling window is sufficient** to capture all orders that need processing; orders older than 3 days are assumed to be finalized and no longer require updates.
6. **Parquet files in S3 are not corrupted** and Spectrum can read them without errors.

### What Could Break If Upstream Changes

| Upstream Change | Impact | Mitigation |
|-----------------|--------|-----------|
| **New order status values** (e.g., `cancelled_by_system_v2`) | Filtered orders would no longer be excluded; revenue metrics would spike. | Maintain a curated list of excluded statuses; update filter logic quarterly. |
| **Timezone shift in `created_at`** | Order dates would shift; daily reports would show orders on wrong dates. | Add explicit timezone conversion; validate `order_date` distribution before/after changes. |
| **Null values in `total_amount`** | WHERE clause `total_amount > 0` would exclude them; orders would silently disappear. | Add data quality check upstream; alert if NULL count exceeds threshold. |
| **S3 parquet schema changes** (new/removed columns) | Spectrum table definition would break; this query would fail. | Version parquet schemas; use schema evolution in Spectrum definition. |
| **Removal of `is_test` column** | Query would fail at parse time. | Add defensive column existence check; document required source columns. |
| **Duplicate order IDs** in source | Fact tables would have inflated row counts; revenue would be overstated. | Add `COUNT(DISTINCT order_id)` validation; alert if count changes unexpectedly. |

## Performance Notes

### Distribution Key: `DISTKEY(order_id)`
Orders are distributed across Redshift nodes by `order_id`. This is optimal because:
- Downstream joins to `fct_orders` and `dim_orders` typically filter/join on `order_id`, keeping data co-located on the same node.
- Avoids expensive cross-node shuffles for order-level aggregations.
- Assumes relatively even distribution of order IDs across time (no hot spots).

**Risk:** If order IDs are sequential and new orders always go to the same node, distribution could become skewed over time.

### Sort Key: `SORTKEY(order_date)`
Rows are physically sorted by `order_date` within each node. Benefits:
- Queries filtering by date range (e.g., `WHERE order_date BETWEEN '2024-01-01' AND '2024-01-31'`) can use zone maps to skip blocks.
- Time-series aggregations (`GROUP BY order_date`) are faster due to locality.
- Aligns with the rolling 3-day window logic; recent data is clustered together.

**Trade-off:** Sorts by date, not by `order_id`. Lookups by single order ID may require full table scan.

### Full Table Rebuild (DROP and CREATE)
The query uses `DROP TABLE IF EXISTS` followed by `CREATE TABLE AS SELECT`, which:
- **Pros:** Eliminates dead rows and fragmentation; ensures clean state; simple to reason about.
- **Cons:** Requires exclusive lock; blocks all downstream queries during rebuild (~5-10 minutes for typical order volumes); no incremental updates.

**Optimization opportunity:** Consider switching to incremental upsert (INSERT/UPDATE) if 3-day rebuild window becomes a bottleneck.

### Spectrum External Table Scan
Reading from `spectrum.raw_orders` (S3-backed) is slower than reading from native Redshift tables. Each query must:
- List S3 objects (metadata overhead).
- Deserialize parquet files (CPU-intensive).
- Transfer data from S3 to Redshift nodes (network I/O).

**Mitigation:** Spectrum is acceptable for daily batch ingestion; avoid querying `spectrum.raw_orders` directly in production queries. Always use `staging.stg_raw_orders` instead.

### ANALYZE Statement
The `ANALYZE` command updates table statistics (row count, column distributions) used by the query planner. Essential for:
- Accurate cardinality estimates in downstream queries.
- Correct join order selection.

**Note:** Should complete in <1 minute for typical order volumes.

## Dependencies

### Upstream (Must Run Before This Component)
- **spectrum.raw_orders** — External table definition must exist and point to valid S3 parquet files. Typically created by infrastructure-as-code (Terraform/CloudFormation) during Redshift cluster setup. If S3 files are missing or corrupted, this query will fail.
- **S3 parquet files** — Raw order data must be written to S3 by the operational system (e.g., CDC pipeline, nightly export). Assumed to be available before 02:00 UTC daily.

### Downstream (Components That Depend on This Output)
- **marts.fct_orders** — Fact table that joins `stg_raw_orders` to create order-level metrics. Runs at 03:00 UTC (1 hour after this component).
- **marts.dim_orders** — Dimension table for order attributes. Depends on `stg_raw_orders` for order status, channel, and payment method.
- **reports.revenue_daily** — Daily revenue report aggregates `stg_raw_orders` by date and channel.
- **reports.customer_ltv** — Customer lifetime value calculation sums `total_amount` from `stg_raw_orders` grouped by `customer_id`.
- **Ad-hoc analytics queries** — `analytics_readers` group queries this table directly for exploratory analysis.

### External Dependencies
- **Redshift cluster** — Must have sufficient disk space for the table (typically 50-200 GB depending on order volume).
- **IAM role** — Redshift service role must have S3 `GetObject` and `ListBucket` permissions on the parquet file location.
- **Spectrum metadata database** — External schema `spectrum` must exist and be configured to point to the correct S3 location.
- **Scheduler (Airflow/dbt Cloud/etc.)** — External orchestration tool must trigger this query at 02:00 UTC daily and handle failure notifications.

### Access Control
- **GRANT SELECT TO GROUP analytics_readers** — Allows members of the `analytics_readers` group to query this table. Typically includes analysts, BI engineers, and data scientists.
- **No INSERT/UPDATE/DELETE permissions** — Only Data Engineering can modify this table (via daily rebuild).

---

## Maintenance & Monitoring Checklist

- [ ] **Daily:** Verify query completes before 03:00 UTC (1-hour SLA before downstream jobs).
- [ ] **Weekly:** Check row count trend; alert if count drops >10% (indicates upstream data loss).
- [ ] **Monthly:** Review `_loaded_at` distribution; ensure no stale records older than 3 days.
- [ ] **Quarterly:** Validate that filtered-out orders (test, cancelled_by_system) are actually invalid; adjust filters if business rules change.
- [ ] **Annually:** Review distribution/sort key effectiveness; consider redistribution if skew detected.