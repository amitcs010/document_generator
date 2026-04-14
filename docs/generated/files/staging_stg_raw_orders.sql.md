# staging/stg_raw_orders.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (materialized)
- **Schedule:** Daily at 02:00 UTC
- **Owner:** Data Engineering
- **Refresh Strategy:** Full rebuild (DROP and CREATE)

---

## Purpose

This component ingests raw order transaction data from S3-backed Spectrum external tables into Redshift, standardizing data types, applying business-critical filters, and preparing clean order records for downstream analytics and reporting. It serves as the single source of truth for order data across the analytics platform, consumed by fact tables, dashboards, and business intelligence tools that depend on reliable, consistently-formatted order information.

---

## Inputs

| Source | Purpose | Notes |
|--------|---------|-------|
| **spectrum.raw_orders** | Raw order transaction records from S3 parquet files | External table pointing to S3 data lake; contains unvalidated, mixed-type data from the transactional system |

---

## Outputs

| Target | Contents | Consumers |
|--------|----------|-----------|
| **staging.stg_raw_orders** | Cleaned, type-cast order records with business filters applied | Fact tables (fct_orders), dimensional models, analytics dashboards, revenue reporting, customer analytics, order fulfillment workflows |

---

## Key Business Logic

### 1. **Type Standardization & Casting**
All incoming columns are explicitly cast to target types (BIGINT, VARCHAR, DECIMAL, TIMESTAMP). This ensures:
- Numeric fields (amounts, IDs) are properly typed for aggregations and joins
- String fields have consistent lengths (e.g., country codes as VARCHAR(2))
- Monetary amounts use DECIMAL(12,2) to prevent floating-point precision errors in financial calculations
- Timestamps are converted from raw string/datetime formats to Redshift TIMESTAMP for time-series operations

### 2. **Date/Timestamp Decomposition**
- `order_date` (DATE): Extracted from `created_at` for day-level grouping and reporting
- `order_timestamp` (TIMESTAMP): Full precision timestamp for intra-day analysis and audit trails
- `updated_at` (TIMESTAMP): Tracks order modifications for SLA monitoring and change detection

### 3. **Null Handling with Business Defaults**
- `coupon_code`: Defaults to `'NONE'` when null, enabling clean aggregations without filtering out non-coupon orders
- `order_channel`: Defaults to `'web'` when null, assuming web is the primary channel and handling legacy data gaps

### 4. **Test Data Exclusion**
- `WHERE o.is_test = FALSE`: Removes synthetic/QA orders that would skew metrics
- `AND o.status != 'cancelled_by_system'`: Filters out system-generated cancellations (likely refunds or reversals) that don't represent real customer intent
- `AND o.total_amount > 0`: Excludes zero-value orders (returns, adjustments, or data errors) from revenue calculations

### 5. **Rolling Window Ingestion**
- `WHERE o.created_at >= DATEADD(day, -3, GETDATE())`: Loads only the last 3 days of data
- **Rationale:** Balances freshness with performance; assumes late-arriving data arrives within 3 days and enables incremental processing patterns
- **Risk:** Orders created >3 days ago but updated recently will not be captured; requires separate late-arrival handling if needed

### 6. **Load Timestamp Tracking**
- `_loaded_at`: Captured as GETDATE() at execution time for audit trails, data lineage, and freshness monitoring

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **order_id** | BIGINT | Unique order identifier; primary key | 1000001, 1000002 |
| **customer_id** | BIGINT | Foreign key to customer dimension; enables customer-level aggregation | 500, 1200 |
| **order_number** | VARCHAR(50) | Human-readable order reference (often prefixed with channel/date codes) | ORD-2024-001234, WEB-20240115-5678 |
| **order_status** | VARCHAR(20) | Current fulfillment state; used for pipeline stage analysis | pending, confirmed, shipped, delivered, returned |
| **order_date** | DATE | Date order was created; primary time dimension for reporting | 2024-01-15 |
| **order_timestamp** | TIMESTAMP | Full timestamp of order creation; enables intra-day analysis | 2024-01-15 14:32:45 |
| **updated_at** | TIMESTAMP | Last modification timestamp; tracks order lifecycle changes | 2024-01-16 09:15:22 |
| **total_amount** | DECIMAL(12,2) | Total order value including all charges; primary revenue metric | 149.99, 2500.00 |
| **discount_amount** | DECIMAL(12,2) | Promotional/coupon discount applied; used for discount impact analysis | 10.00, 0.00 |
| **shipping_amount** | DECIMAL(12,2) | Shipping cost charged to customer; enables margin analysis | 5.99, 0.00 (free shipping) |
| **tax_amount** | DECIMAL(12,2) | Sales tax collected; used for tax reporting and compliance | 12.50, 0.00 |
| **coupon_code** | VARCHAR(50) | Promotion code applied; defaults to 'NONE' if not used | SAVE10, WELCOME20, NONE |
| **payment_method** | VARCHAR(30) | Payment instrument used; enables payment method analysis | credit_card, paypal, apple_pay, bank_transfer |
| **order_channel** | VARCHAR(30) | Sales channel; defaults to 'web' if null; enables omnichannel reporting | web, mobile_app, phone, retail_store |

---

## Data Quality & Edge Cases

### Null Handling Strategy
| Field | Handling | Rationale |
|-------|----------|-----------|
| coupon_code | NVL → 'NONE' | Distinguishes "no coupon used" from missing data; enables clean GROUP BY |
| order_channel | NVL → 'web' | Assumes web is default; prevents null-related aggregation issues |
| Other fields | Implicit NULL | Preserved as-is; downstream logic handles nulls (e.g., COALESCE in fact tables) |

### Deduplication Strategy
- **No explicit deduplication:** Assumes `spectrum.raw_orders` contains unique records per order_id
- **Risk:** If source system produces duplicates (e.g., CDC replication lag), this table will inherit them
- **Mitigation:** Recommend adding `ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY updated_at DESC)` if duplicates are detected

### Key Assumptions About Upstream Data
1. **Timestamp Format:** `created_at` and `updated_at` are valid datetime strings parseable by CONVERT()
2. **Numeric Precision:** Monetary amounts fit within DECIMAL(12,2) range (max ~$9,999,999.99)
3. **Country Codes:** `billing_country` and `shipping_country` are ISO 3166-1 alpha-2 codes (2 characters)
4. **Status Values:** `status` field contains only expected values (pending, confirmed, shipped, etc.); no typos or unexpected states
5. **Test Flag:** `is_test` boolean is reliably set by source system; no test orders leak through as FALSE

### Potential Failure Points
| Scenario | Impact | Mitigation |
|----------|--------|-----------|
| **Upstream schema change** (e.g., `created_at` renamed) | CAST fails; table creation aborts | Add schema validation in orchestration; alert on column mismatch |
| **Null in required field** (e.g., order_id) | Rows silently dropped or cause join failures downstream | Add NOT NULL constraints post-load; validate row counts |
| **Monetary amount overflow** (e.g., $50M order) | DECIMAL(12,2) truncates; data loss | Increase precision to DECIMAL(14,2) or add validation rule |
| **Timestamp parsing failure** (e.g., malformed date string) | CONVERT() returns NULL or errors | Add TRY_CONVERT() with fallback; log failures |
| **Late-arriving data >3 days old** | Orders missing from staging table | Implement separate late-arrival batch or extend window to 7 days |

---

## Performance Notes

### Distribution & Sort Keys
| Key | Type | Rationale |
|-----|------|-----------|
| **order_id** | DISTKEY | Primary join key across fact/dimension tables; ensures co-location of related rows on same node |
| **order_date** | SORTKEY | Time-series queries (e.g., "orders by day") benefit from sorted scans; enables zone map pruning |

**Implication:** Queries filtering by order_date will use zone maps for efficient range scans; queries joining on order_id avoid network shuffles.

### Join Strategy
- **No joins in this layer:** All data comes from single source table
- **Upstream consideration:** Spectrum external table scans may be slower than native Redshift tables; consider materializing if query performance degrades

### Expensive Operations
| Operation | Cost | Notes |
|-----------|------|-------|
| **DROP TABLE IF EXISTS** | Low | Metadata operation; no data scan |
| **CREATE TABLE AS SELECT** | Medium | Full table scan of spectrum.raw_orders; network I/O from S3 |
| **WHERE clause filtering** | Low | Predicate pushdown to Spectrum; S3 parquet pruning by created_at |
| **CAST operations** | Low | Type conversion in-memory; no I/O |
| **ANALYZE** | Medium | Scans table to update statistics; necessary for query optimization |

### Partitioning Considerations
- **Current approach:** No explicit partitioning; relies on SORTKEY for performance
- **Recommendation:** If table grows >100GB, consider partitioning by order_date (monthly) to improve vacuum and maintenance performance
- **Alternative:** Implement incremental loading (INSERT instead of DROP/CREATE) with date-based partitions for faster refreshes

---

## Dependencies

### Upstream
| Component | Type | Requirement | Notes |
|-----------|------|-------------|-------|
| **spectrum.raw_orders** | External Table | Must exist and be readable | Points to S3 parquet files; requires Spectrum IAM role and S3 permissions |
| **S3 data lake** | Infrastructure | S3 path must contain valid parquet files | Typically s3://data-lake-bucket/raw/orders/ |
| **Redshift cluster** | Infrastructure | Must have available compute and storage | Assumes cluster is running and accessible |

### Downstream
| Component | Type | Dependency Reason |
|-----------|------|-------------------|
| **fct_orders** (Fact Table) | Fact | Primary source for order fact records; joined with dimensions |
| **dim_customers** | Dimension | Customer analytics; customer_id foreign key |
| **dim_products** | Dimension | Product-level order analysis (via order line items) |
| **Revenue Dashboard** | BI Tool | Daily revenue, order count, AOV metrics |
| **Order Fulfillment Pipeline** | Workflow | Triggers fulfillment processes based on order_status |
| **Customer Analytics** | Analytics | Cohort analysis, RFM segmentation, churn prediction |
| **Finance Reporting** | Report | Revenue recognition, tax reporting, reconciliation |

### External Dependencies
| Dependency | Type | Purpose |
|------------|------|---------|
| **IAM Role (Spectrum)** | AWS | S3 read permissions for Spectrum external table |
| **S3 Bucket Policy** | AWS | Allows Redshift to access parquet files |
| **Orchestration Tool** (Airflow/dbt Cloud) | Scheduler | Triggers daily 02:00 UTC execution |
| **analytics_readers Group** | Redshift | Access control; downstream users granted SELECT via this group |

---

## Maintenance & Monitoring

### Health Checks
- **Row count trend:** Alert if daily row count drops >20% (indicates upstream data issue)
- **Load duration:** Alert if execution time exceeds 30 minutes (indicates performance degradation)
- **Null rates:** Monitor null percentages in key columns (order_id, total_amount); alert if >1%

### Known Limitations
1. **3-day rolling window:** Orders created >3 days ago but updated recently are not refreshed
2. **No late-arrival handling:** Assumes all data arrives within 3 days
3. **No deduplication:** Inherits duplicates from source if they exist
4. **Full rebuild:** Inefficient for large tables; consider incremental loading for scale

### Future Enhancements
- Implement incremental loading with date-based partitions
- Add data quality checks (e.g., dbt tests for null rates, referential integrity)
- Separate test data handling into configurable filter
- Add SCD Type 2 tracking for order status changes