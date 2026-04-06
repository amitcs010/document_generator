# staging/stg_raw_orders.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (materialized, full refresh)
- **Schedule:** Daily at 02:00 UTC
- **Owner:** Data Engineering
- **SLA:** Must complete before 06:00 UTC (assumed, based on typical analytics load windows)

---

## Purpose

This component ingests raw order transaction data from S3-backed Spectrum tables into Redshift, applying standardized type casting, business rule filtering, and data quality checks. It serves as the single source of truth for order data across the analytics platform, enabling downstream reporting, BI dashboards, and financial reconciliation. The staging layer acts as a buffer between volatile source systems and trusted analytics models, ensuring consistent data contracts for all downstream consumers.

---

## Inputs

| Source | Purpose | Criticality |
|--------|---------|-------------|
| **spectrum.raw_orders** | Raw order events from transactional database, synced to S3 parquet files. Contains all order attributes including IDs, amounts, dates, methods, and metadata flags. | Critical — sole source of order truth |

---

## Outputs

| Target | Contents | Consumers |
|--------|----------|-----------|
| **staging.stg_raw_orders** | Cleaned, typed, and filtered order records with standardized column names and formats. Includes 3-day rolling window of valid orders. | `mart_orders`, `mart_financials`, `rpt_daily_sales`, `dashboard_orders_realtime`, ad-hoc analytics queries |

---

## Key Business Logic

### 1. **Type Standardization**
All columns are explicitly cast to target types (BIGINT for IDs, DECIMAL(12,2) for monetary amounts, VARCHAR for codes). This prevents downstream type coercion errors and ensures consistent precision for financial calculations (e.g., total_amount always has exactly 2 decimal places for currency).

### 2. **Date/Timestamp Normalization**
- `order_date` is extracted as DATE from `created_at` for day-level grouping in reports
- `order_timestamp` preserves full precision for intra-day analysis and deduplication
- `updated_at` tracks when orders were last modified (used for SCD Type 2 logic in downstream marts)

### 3. **Monetary Amount Validation**
Filter `WHERE total_amount > 0` excludes:
- Refunded orders (negative amounts)
- Placeholder/draft orders (zero amounts)
- Data entry errors

This ensures financial reports only count settled transactions.

### 4. **Test Data Exclusion**
`WHERE o.is_test = FALSE` removes orders created by QA/development teams, preventing inflated revenue metrics and skewed customer counts in production dashboards.

### 5. **System-Cancelled Order Exclusion**
`WHERE o.status != 'cancelled_by_system'` filters out orders cancelled by automated processes (e.g., payment failures, inventory holds). These are tracked separately in operational dashboards but excluded from revenue/fulfillment metrics to avoid double-counting with refunds.

### 6. **Rolling 3-Day Window**
`WHERE o.created_at >= DATEADD(day, -3, GETDATE())` implements incremental loading:
- Reduces compute cost vs. full table scans
- Captures late-arriving data (orders created 1-2 days ago but updated today)
- Assumes source system guarantees no changes to orders >3 days old (verify with source team)

### 7. **Default Value Imputation**
- `coupon_code`: NULL → 'NONE' (enables GROUP BY without filtering nulls; distinguishes "no coupon" from "missing data")
- `order_channel`: NULL → 'web' (assumes web is default channel; verify with product team if this assumption holds)

### 8. **Load Timestamp**
`_loaded_at` = GETDATE() records when each row was materialized, enabling:
- Freshness monitoring (alert if _loaded_at is >24 hours old)
- Debugging late-arriving data
- Audit trails for compliance

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **order_id** | BIGINT | Unique order identifier from source system. Primary key. | 1001, 1002, 1003 |
| **customer_id** | BIGINT | Foreign key to customer dimension. Links orders to customer profiles. | 501, 502, 503 |
| **order_number** | VARCHAR(50) | Human-readable order reference (e.g., for customer service). May not be unique if system reuses numbers. | "ORD-2024-001", "PO-12345" |
| **order_status** | VARCHAR(20) | Current fulfillment state. Standardized enum from source. | 'pending', 'confirmed', 'shipped', 'delivered', 'returned' |
| **order_date** | DATE | Date order was created (UTC). Used for daily aggregations and trend analysis. | 2024-01-15 |
| **order_timestamp** | TIMESTAMP | Full timestamp of order creation (UTC). Enables intra-day analysis and precise deduplication. | 2024-01-15 14:32:45 |
| **updated_at** | TIMESTAMP | Last modification timestamp. Tracks when order status/amounts changed. | 2024-01-16 09:15:22 |
| **total_amount** | DECIMAL(12,2) | Final order value after discounts, tax, and shipping. Used for revenue calculations. | 99.99, 1250.50 |
| **discount_amount** | DECIMAL(12,2) | Total promotional discount applied. Negative values indicate discounts. | 10.00, 25.50 |
| **shipping_amount** | DECIMAL(12,2) | Shipping cost charged to customer. | 5.99, 0.00 (free shipping) |
| **tax_amount** | DECIMAL(12,2) | Sales/VAT tax calculated by source system. | 7.50, 0.00 (tax-exempt) |
| **coupon_code** | VARCHAR(50) | Promotional code used. 'NONE' if no coupon applied. | 'SUMMER20', 'WELCOME10', 'NONE' |
| **payment_method** | VARCHAR(30) | How customer paid. Standardized enum. | 'credit_card', 'paypal', 'apple_pay', 'bank_transfer' |
| **order_channel** | VARCHAR(30) | Sales channel. Defaults to 'web' if null. | 'web', 'mobile_app', 'phone', 'in_store' |
| **_loaded_at** | TIMESTAMP | When this row was loaded into staging. Used for freshness monitoring. | 2024-01-17 02:15:33 |

---

## Data Quality & Edge Cases

### Null Handling
| Column | Null Behavior | Rationale |
|--------|---------------|-----------|
| `coupon_code` | Imputed to 'NONE' | Enables GROUP BY aggregations without filtering; distinguishes "no coupon" from "missing data" |
| `order_channel` | Imputed to 'web' | Assumes web is default; **verify this assumption with product team** |
| `discount_amount`, `shipping_amount`, `tax_amount` | Preserved as NULL | Indicates data not yet calculated (e.g., pending orders); downstream logic must handle |
| `order_number` | Preserved as NULL | Rare but possible; indicates order not yet assigned reference number |

### Deduplication Strategy
**No explicit deduplication.** Assumes:
- Source system (spectrum.raw_orders) enforces unique constraint on `order_id`
- If duplicates exist in source, this query will propagate them
- **Action:** Add deduplication if source has known duplicate issues:
  ```sql
  ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY updated_at DESC) AS rn
  WHERE rn = 1
  ```

### Assumptions About Upstream Data
1. **No future-dated orders:** `created_at` is always ≤ GETDATE()
2. **Monotonic timestamps:** `updated_at` ≥ `created_at` (always)
3. **Amount consistency:** `total_amount` = `discount_amount` + `shipping_amount` + `tax_amount` + line_items (verify with finance)
4. **Status enum:** Only valid statuses exist (no typos like 'shiped' vs 'shipped')
5. **3-day window assumption:** No orders are modified after 3 days (if violated, incremental loads will miss updates)

### What Could Break

| Scenario | Impact | Mitigation |
|----------|--------|-----------|
| Source adds new `status` value (e.g., 'on_hold') | Downstream filters may silently exclude new orders | Add data quality check: `SELECT DISTINCT status FROM spectrum.raw_orders` |
| `created_at` contains timezone info (not UTC) | Date calculations off by hours; revenue reports misaligned to business day | Verify source system always stores UTC; add timezone conversion if needed |
| Negative `total_amount` for refunds not filtered | Revenue metrics inflated/deflated; financial reconciliation fails | Clarify with finance: should refunds be in separate table or flagged differently? |
| `coupon_code` contains NULL for "no coupon" in source | Imputation to 'NONE' creates artificial rows; GROUP BY results misleading | Audit source data; adjust imputation logic if needed |
| 3-day window misses late-arriving data | Orders created 4+ days ago but updated today are excluded | Extend window to 7-10 days; monitor `updated_at - created_at` lag distribution |
| Spectrum table schema changes (column renamed/removed) | Query fails at runtime; no data loaded | Add schema validation step before DROP TABLE |

---

## Performance Notes

### Distribution & Sort Keys
| Key | Choice | Rationale |
|-----|--------|-----------|
| **DISTKEY(order_id)** | Order ID | Enables efficient joins with downstream fact tables (mart_orders, mart_order_items) on order_id; minimizes data movement across nodes |
| **SORTKEY(order_date)** | Order date | Optimizes time-series queries (e.g., "revenue by day"); enables zone map pruning for date range filters |

### Join Strategy
- **No joins in this layer.** Single-table SELECT from spectrum.raw_orders
- Spectrum table is external (S3-backed), so Redshift scans parquet files directly
- **Cost:** Full table scan of S3 parquet files, but filtered to 3-day window (reduces I/O)

### Expensive Operations
| Operation | Cost | Mitigation |
|-----------|------|-----------|
| **CONVERT(DATE, o.created_at)** | Low — simple type cast | Acceptable; runs once per row |
| **CONVERT(TIMESTAMP, o.created_at)** | Low — simple type cast | Acceptable; runs once per row |
| **DATEADD(day, -3, GETDATE())** | Negligible — scalar function | Runs once per query; pre-compute if needed |
| **CAST(... AS DECIMAL(12,2))** | Low — type conversion | Acceptable; ensures precision for financial data |
| **ANALYZE** | Medium — full table scan | Runs post-load; updates table statistics for query planner; necessary for performance |

### Full Table Scans
- **Spectrum.raw_orders:** Full scan of S3 parquet files (no partition pruning available in Spectrum)
- **Mitigation:** 3-day rolling window reduces data scanned; consider partitioning S3 data by date if scans become expensive

### Estimated Query Runtime
- **Typical:** 2-5 minutes (depends on S3 parquet file size and network latency)
- **Monitor:** If runtime exceeds 10 minutes, investigate S3 performance or Spectrum configuration

---

## Dependencies

### Upstream (Must Run Before This Component)
| Component | Purpose | Frequency |
|-----------|---------|-----------|
| **S3 data sync job** | Syncs transactional database to S3 parquet files (spectrum.raw_orders) | Hourly or real-time CDC |
| **Spectrum table creation** | Defines external table schema for S3 parquet files | One-time setup; re-run if schema changes |

### Downstream (Depends on This Component's Output)
| Component | Purpose | Frequency |
|-----------|---------|-----------|
| **mart_orders** | Dimensional model of orders; joins with customer/product dimensions | Daily (depends on stg_raw_orders) |
| **mart_financials** | Revenue, discount, tax aggregations for accounting reconciliation | Daily (depends on stg_raw_orders) |
| **rpt_daily_sales** | Executive dashboard: daily revenue, order count, AOV | Daily (depends on mart_orders) |
| **dashboard_orders_realtime** | Real-time order status tracking for operations team | Hourly (depends on stg_raw_orders) |
| **Ad-hoc analytics queries** | Data scientists, analysts querying raw order data | On-demand |

### External Dependencies
| System | Purpose | Failure Impact |
|--------|---------|----------------|
| **S3 (AWS)** | Stores parquet files for spectrum.raw_orders | If S3 unavailable, query fails; no data loaded |
| **Spectrum** | External table layer connecting Redshift to S3 | If Spectrum misconfigured, query fails |
| **Redshift cluster** | Compute engine for query execution | If cluster down/paused, query fails |
| **analytics_readers group** | IAM role for downstream consumers | If permissions revoked, downstream queries fail |

### Monitoring & Alerting
- **Alert if:** `_loaded_at` is >24 hours old (indicates load failure)
- **Alert if:** Row count drops >20% vs. previous day (indicates filtering too aggressive or data quality issue)
- **Alert if:** Query runtime exceeds 10 minutes (indicates S3 or Spectrum performance degradation)

---

## Maintenance & Troubleshooting

### Common Issues

**Issue:** Query fails with "Spectrum table not found"
- **Cause:** Spectrum external table not created or schema changed
- **Fix:** Verify Spectrum table exists: `SELECT * FROM spectrum.raw_orders LIMIT 1`

**Issue:** Row count is zero or unexpectedly low
- **Cause:** 3-day rolling window excludes older data; test data filter too aggressive
- **Fix:** Check source data: `SELECT COUNT(*) FROM spectrum.raw_orders WHERE created_at >= DATEADD(day, -3, GETDATE())`

**Issue:** Downstream queries fail with type mismatch
- **Cause:** Column type changed in source; CAST failed silently
- **Fix:** Add explicit error handling: `TRY_CAST(o.total_amount AS DECIMAL(12,2))`

### Refresh Strategy
- **Full refresh:** DROP and recreate table daily (current approach)
- **Alternative:** Incremental upsert (if source provides change data capture)
- **Pros of full refresh:** Simple, no deduplication logic needed, clean state
- **Cons:** Expensive for large tables; consider incremental if table grows >1B rows

---

## Related Documentation
- [Spectrum Configuration Guide](link)
- [Data Quality Standards](link)
- [Downstream Mart: mart_orders](link)
- [Financial Reconciliation Process](link)