# staging/stg_raw_products.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (full refresh)
- **Schedule:** Not specified in code; infer from orchestration metadata
- **Owner:** Not specified in code; infer from data governance system

---

## Purpose

This component ingests and standardizes the raw product catalog from the inventory management system into a cleaned, consistently-typed staging table. It serves as the single source of truth for all downstream product dimensions, analytics, and reporting by normalizing data types, decoding status values, and applying basic data quality filters. The output is consumed by dimensional modeling layers (e.g., `dim_products`) and analytical queries that require a reliable, deduplicated product reference.

---

## Inputs

| Source | Purpose | Notes |
|--------|---------|-------|
| **spectrum.raw_products** | Raw product catalog from the inventory system | Spectrum is an external data lake; this table is likely refreshed on a schedule independent of this pipeline. Contains denormalized product attributes including pricing, categorization, and inventory metadata. |

---

## Outputs

| Target | Contents | Consumers |
|--------|----------|-----------|
| **staging.stg_raw_products** | Cleaned, standardized product master data with 15 columns including product identifiers, categorization, pricing, and operational metadata | Downstream dimensional tables (`dim_products`), fact tables requiring product keys, analytics dashboards, and ad-hoc product analysis queries |

---

## Key Business Logic

### 1. **Type Casting & Standardization**
All columns are explicitly cast to target data types (BIGINT, VARCHAR, DECIMAL, DATE). This ensures:
- Consistent precision for financial data (unit_price, unit_cost as DECIMAL(10,2))
- Consistent string lengths for lookups (SKU capped at 50 chars, product_name at 200)
- Prevents downstream type coercion errors and ensures predictable sorting/grouping behavior

### 2. **Status Decoding (SCD Type 1)**
The `product_status` column decodes single-character codes into human-readable values:
```
'A' → 'Active'
'D' → 'Discontinued'
'O' → 'Out of Stock'
NULL/other → 'Unknown'
```
This transformation:
- Makes reports and dashboards more interpretable to business users
- Centralizes status logic in one place (reduces duplication in downstream queries)
- Implements SCD Type 1 semantics: each product_id has only the latest status (full overwrite, no history)

### 3. **Null Handling for Foreign Keys**
`supplier_id` is coalesced to `-1` when NULL:
- Prevents NULL foreign key issues in downstream joins
- Allows filtering for "products with unknown supplier" via `WHERE supplier_id = -1`
- Maintains referential integrity assumptions in dimensional models

### 4. **Date Normalization**
`launch_date` and `last_restock_date` are converted to DATE type (removing time components):
- Simplifies date-based filtering and grouping in downstream queries
- Ensures consistent date granularity across the warehouse
- Prevents timezone or time-of-day artifacts from affecting business logic

### 5. **Data Quality Filtering**
The WHERE clause enforces two mandatory constraints:
```sql
WHERE p.id IS NOT NULL
  AND p.name IS NOT NULL
```
This ensures:
- No orphaned records without a product identifier
- No products without a name (which would be meaningless in reports)
- Reduces downstream null-handling complexity

### 6. **Full Refresh Strategy**
The table is dropped and recreated (not upserted):
- Simplifies logic: no need to track which records changed
- Ensures stale records are automatically removed (e.g., if a product is deleted from the source)
- Assumes the source system is the system of record; staging always reflects current state

### 7. **Load Timestamp**
`_loaded_at` is set to GETDATE() (current execution time):
- Enables traceability and debugging (when was this data last refreshed?)
- Supports SLA monitoring and data freshness checks
- Allows downstream queries to filter for "products loaded after X time"

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **product_id** | BIGINT | Unique product identifier; primary key from source system | 1001, 5432, 999999 |
| **sku** | VARCHAR(50) | Stock Keeping Unit; human-readable product code used in inventory systems | "WIDGET-A-001", "GADGET-B-XL" |
| **product_name** | VARCHAR(200) | Full product name for display in reports and dashboards | "Deluxe Widget Pro", "Standard Gadget" |
| **category** | VARCHAR(100) | Top-level product category for segmentation | "Electronics", "Home & Garden", "Apparel" |
| **subcategory** | VARCHAR(100) | Secondary product category for finer segmentation | "Smartphones", "Outdoor Tools", "Men's Clothing" |
| **brand** | VARCHAR(100) | Manufacturer or brand name | "TechCorp", "HomeMax", "StyleBrand" |
| **unit_price** | DECIMAL(10,2) | Current selling price per unit; used in revenue calculations | 29.99, 149.50, 0.99 |
| **unit_cost** | DECIMAL(10,2) | Current cost per unit; used in margin and profitability analysis | 15.00, 75.25, 0.45 |
| **weight_kg** | DECIMAL(8,3) | Product weight in kilograms; used for shipping cost estimation and logistics | 0.250, 2.500, 15.750 |
| **product_status** | VARCHAR(20) | Operational status of the product (Active/Discontinued/Out of Stock/Unknown) | "Active", "Discontinued", "Out of Stock" |
| **supplier_id** | BIGINT | Foreign key to supplier master; -1 indicates unknown/null supplier | 101, 205, -1 |
| **launch_date** | DATE | Date product was first introduced to market; used for product age analysis | 2023-01-15, 2022-06-30 |
| **last_restock_date** | DATE | Most recent date inventory was replenished; used for freshness and demand analysis | 2024-01-10, 2023-12-28 |
| **inventory_count** | INT | Current on-hand inventory quantity; used for stock-out risk analysis | 0, 150, 5000 |
| **_loaded_at** | TIMESTAMP | Timestamp when this record was loaded into staging; used for freshness monitoring | 2024-01-15 14:32:15, 2024-01-16 02:00:00 |

---

## Data Quality & Edge Cases

### Null Handling

| Column | Null Behavior | Rationale |
|--------|---------------|-----------|
| **product_id, product_name** | Filtered out (WHERE clause) | These are mandatory identifiers; records without them are unusable |
| **supplier_id** | Coalesced to -1 | Allows joins without NULL propagation; enables "unknown supplier" filtering |
| **launch_date, last_restock_date** | Passed through as NULL | May be legitimately unknown for legacy products; downstream queries should handle gracefully |
| **inventory_count** | Passed through as NULL | May indicate data not yet synced; should be treated as "unknown" not "zero" |
| **category, subcategory, brand** | Passed through as NULL | May be valid for unclassified products; downstream queries should use COALESCE or CASE for reporting |

### Deduplication Strategy

**No explicit deduplication is performed.** The code assumes:
- `spectrum.raw_products` contains one row per product_id (enforced at source)
- If duplicates exist in the source, the last row processed by the SELECT will be retained (undefined behavior in Redshift; risky assumption)

**Risk:** If the source table contains duplicate product_ids, this code will silently produce non-deterministic results.

**Recommendation:** Add explicit deduplication:
```sql
ROW_NUMBER() OVER (PARTITION BY p.id ORDER BY p.updated_at DESC) AS rn
-- Then: WHERE rn = 1
```

### Assumptions About Upstream Data

1. **Status codes are limited to {A, D, O}** — If new codes are introduced, they map to 'Unknown' (safe fallback, but may mask data quality issues)
2. **Numeric columns (price, cost, weight) are valid decimals** — If non-numeric strings exist, CAST will fail and the entire load will abort
3. **Date columns are valid DATE or TIMESTAMP types** — If malformed dates exist, CONVERT will fail
4. **product_id is globally unique** — If duplicates exist, behavior is undefined
5. **The source table is always available** — If `spectrum.raw_products` is dropped or renamed, this job fails with no fallback

### What Could Break

| Scenario | Impact | Mitigation |
|----------|--------|-----------|
| New status code (e.g., 'P' for "Pre-order") introduced in source | Maps to 'Unknown'; reports may be inaccurate | Update CASE statement; add monitoring alert for unknown statuses |
| Non-numeric value in price/cost column | CAST fails; entire load aborts; stale data remains in production | Add data quality checks upstream; implement error handling and rollback |
| NULL values in product_id or product_name increase | Fewer products in staging; downstream joins produce fewer matches | Monitor row counts; alert if filtered-out records exceed threshold |
| supplier_id references non-existent suppliers | Foreign key constraint fails in downstream dim_products | Add referential integrity check; validate supplier_id exists in supplier master |
| Duplicate product_ids in source | Non-deterministic output; some products may be silently overwritten | Add explicit deduplication logic; add uniqueness constraint to source |

---

## Performance Notes

### Distribution & Sorting

| Strategy | Choice | Rationale |
|----------|--------|-----------|
| **DISTSTYLE** | ALL | Table is replicated to all nodes. Justification: Product master is relatively small (typically <1M rows), and replication enables efficient local joins in downstream queries without redistribution. If product catalog grows >10M rows, consider DISTKEY(product_id) |
| **SORTKEY** | product_id | Optimizes joins and lookups on product_id (the primary key). Enables efficient range scans and merge joins. Secondary sort keys (e.g., category, status) could improve GROUP BY performance but would increase storage overhead |

### Join Strategy

- **No joins in this query** — This is a simple SELECT from a single source table
- **Downstream impact:** Because the table is DISTSTYLE ALL, downstream joins on product_id will be local (no redistribution), improving query performance

### Expensive Operations

| Operation | Cost | Notes |
|-----------|------|-------|
| **DROP TABLE IF EXISTS** | Low | Metadata operation; no data movement |
| **CREATE TABLE AS SELECT** | Medium | Full table scan of `spectrum.raw_products` + write to staging. Cost scales with source table size. Spectrum queries may incur additional I/O if data is stored in S3 |
| **CAST operations** | Low | Type conversions are applied during SELECT; minimal CPU overhead |
| **CASE statement (status decoding)** | Negligible | Simple string mapping; no aggregation or sorting |
| **ANALYZE** | Medium | Scans entire table to update statistics; necessary for query planner accuracy |

### Full Table Scan

- The SELECT statement performs a **full table scan** of `spectrum.raw_products`
- This is unavoidable for a full refresh; optimization would require incremental loading (e.g., WHERE updated_at > last_load_time)
- **Recommendation:** If source table is very large (>100M rows), consider incremental loading with a change data capture (CDC) mechanism

### Partitioning

- **No partitioning is used** — Redshift does not support table partitioning; instead, it uses SORTKEY for clustering
- If this table grows very large, consider archiving old records to a separate historical table

---

## Dependencies

### Upstream
| Component | Type | Criticality | Notes |
|-----------|------|-------------|-------|
| **spectrum.raw_products** | External table (Redshift Spectrum) | **Critical** | Must be available and contain valid product data. If this table is dropped, renamed, or becomes unavailable, this job fails. No fallback or retry logic is present. |
| **Redshift cluster** | Infrastructure | **Critical** | Requires active Redshift cluster with sufficient compute and storage |

### Downstream
| Component | Type | Dependency Type | Notes |
|-----------|------|-----------------|-------|
| **dim_products** | Dimensional table | **Direct** | Consumes `stg_raw_products` as the source for the product dimension. Any changes to column names or data types will break dim_products |
| **fct_sales** | Fact table | **Indirect** | Joins to dim_products, which depends on this staging table. Data quality issues here propagate to fact tables |
| **Product analytics dashboards** | BI/Reporting | **Indirect** | Dashboards may query this table directly or via dim_products. Stale or missing data affects reporting accuracy |
| **Inventory management reports** | Reporting | **Direct** | May query `inventory_count` and `product_status` directly for stock-out alerts |

### External Dependencies
| Dependency | Type | Impact |
|------------|------|--------|
| **Spectrum S3 bucket** | Data lake storage | If S3 path changes or bucket becomes inaccessible, spectrum.raw_products becomes unavailable |
| **analytics_readers group** | IAM/Access control | GRANT statement assumes this group exists; if it doesn't, the job fails at the GRANT step |
| **Orchestration scheduler** | Workflow management | Job execution frequency and timing depend on external scheduler (Airflow, dbt Cloud, etc.); not visible in code |

---

## Additional Recommendations

### 1. **Add Error Handling**
Current code has no TRY-CATCH or error logging. If any step fails, the transaction rolls back but no alert is triggered.

```sql
BEGIN TRY
  BEGIN TRANSACTION;
  -- ... existing code ...
  COMMIT;
END TRY
BEGIN CATCH
  ROLLBACK;
  RAISERROR('stg_raw_products load failed: %s', 16, 1, ERROR_MESSAGE());
END CATCH;
```

### 2. **Add Row Count Validation**
Detect if the load produced suspiciously few rows (possible data quality issue):

```sql
DECLARE @row_count INT = (SELECT COUNT(*) FROM staging.stg_raw_products);
IF @row_count < 100
  RAISERROR('stg_raw_products has only %d rows; possible data quality issue', 16, 1, @row_count);
```

### 3. **Add Deduplication**
Explicitly handle duplicate product_ids:

```sql
WITH deduplicated AS (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY p.id ORDER BY p.updated_at DESC, p.id DESC) AS rn
  FROM spectrum.raw_products p
)
SELECT ... FROM deduplicated WHERE rn = 1;
```

### 4. **Document Schedule**
Add a comment specifying the expected refresh frequency:

```sql
-- Expected refresh: Daily at 02:00 UTC
-- SLA: Data should be available by 03:00 UTC
```

### 5. **Add Data Quality Checks**
Monitor for anomalies:

```sql
-- Check for unexpected status values
SELECT DISTINCT product_status FROM staging.stg_raw_products
WHERE product_status = 'Unknown';

-- Check for negative prices
SELECT COUNT(*) FROM staging.stg_raw_products
WHERE unit_price < 0 OR unit_cost < 0;
```