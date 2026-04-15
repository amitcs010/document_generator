# staging/stg_raw_products.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (full refresh)
- **Schedule:** Not specified in code; infer from orchestration metadata
- **Owner:** Not specified in code; infer from data governance system

---

## Purpose

This component ingests and standardizes the raw product catalog from the inventory management system into a cleaned, consistently-typed staging table. It serves as the single source of truth for product master data within the analytics platform, enabling downstream dimensional modeling, reporting, and inventory analytics. The staging layer acts as a buffer between the volatile source system and the more stable analytics layer, allowing data quality checks and transformations to be applied consistently before products are used in fact tables and reports.

---

## Inputs

| Source | Purpose | Notes |
|--------|---------|-------|
| **spectrum.raw_products** | Raw product catalog from the inventory system | Contains product attributes (SKU, name, category, pricing, status, supplier relationships, and inventory counts). This is the system of record for product master data. |

---

## Outputs

| Target | Contents | Consumers |
|--------|----------|-----------|
| **staging.stg_raw_products** | Cleaned, standardized product dimension with 14 columns including product identifiers, hierarchical categorization, pricing, cost, physical attributes, status, supplier linkage, and temporal metadata. | Downstream dimensional models (e.g., `marts.dim_products`), inventory analytics, product performance reporting, and any analysis requiring product context. |

---

## Key Business Logic

### 1. **Type Casting & Standardization**
All columns are explicitly cast to target data types (BIGINT, VARCHAR, DECIMAL, DATE). This ensures:
- Consistent data types across the platform (prevents implicit conversion errors downstream)
- Predictable precision for financial fields (unit_price, unit_cost at 2 decimal places; weight_kg at 3 decimals)
- Explicit VARCHAR length constraints prevent truncation surprises

### 2. **Status Code Decoding**
Product status is transformed from single-character codes to human-readable values:
```
'A' → 'Active'
'D' → 'Discontinued'
'O' → 'Out of Stock'
else → 'Unknown'
```
**Why:** Improves readability in reports and dashboards; centralizes business rule encoding so downstream consumers don't need to know source system codes.

### 3. **Supplier ID Null Handling**
Missing supplier IDs are replaced with `-1` using `NVL()`:
```sql
NVL(p.supplier_id, -1) AS supplier_id
```
**Why:** Enables foreign key relationships and aggregations without NULL complications; `-1` is a conventional surrogate key for "unknown/unassigned" in dimensional modeling.

### 4. **Date Conversion**
Launch and restock dates are explicitly converted to DATE type (removing time components):
```sql
CONVERT(DATE, p.launch_date) AS launch_date
```
**Why:** Ensures consistent date granularity; removes time-of-day noise that may exist in source system; enables proper date-based filtering and joins in downstream models.

### 5. **Mandatory Field Filtering**
Only products with non-null `id` and `name` are included:
```sql
WHERE p.id IS NOT NULL
  AND p.name IS NOT NULL
```
**Why:** Prevents orphaned records without identifiers or names from polluting the dimension; ensures every product can be uniquely identified and meaningfully labeled in reports.

### 6. **Full Refresh Strategy (SCD Type 1)**
The entire table is dropped and recreated on each run:
```sql
DROP TABLE IF EXISTS staging.stg_raw_products_tmp;
-- ... CREATE AS SELECT ...
DROP TABLE IF EXISTS staging.stg_raw_products;
ALTER TABLE staging.stg_raw_products_tmp RENAME TO stg_raw_products;
```
**Why:** Implements SCD Type 1 (overwrite), meaning historical versions are not retained. This is appropriate for master data that should always reflect the current state of the inventory system. The tmp table pattern prevents query failures during the swap.

### 7. **Load Timestamp**
`GETDATE()` captures the exact moment the data was staged:
```sql
GETDATE() AS _loaded_at
```
**Why:** Enables traceability and debugging; allows downstream processes to identify which batch a record came from; supports data freshness monitoring.

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **product_id** | BIGINT | Unique product identifier from source system; primary key. | 1001, 5432, 999999 |
| **sku** | VARCHAR(50) | Stock Keeping Unit; human-readable product code used in operations. | 'WIDGET-001', 'GADGET-XL-BLU' |
| **product_name** | VARCHAR(200) | Full product name for display in reports and dashboards. | 'Deluxe Widget Pro', 'Compact Gadget' |
| **category** | VARCHAR(100) | Top-level product hierarchy; used for high-level segmentation. | 'Electronics', 'Office Supplies', 'Furniture' |
| **subcategory** | VARCHAR(100) | Secondary product hierarchy; enables finer-grained analysis. | 'Laptops', 'Desk Accessories', 'Chairs' |
| **brand** | VARCHAR(100) | Manufacturer or brand name; used for brand-level reporting. | 'TechCorp', 'OfficeMax', 'FurniturePro' |
| **unit_price** | DECIMAL(10,2) | Current selling price per unit; used in revenue calculations. | 99.99, 1250.50, 5.00 |
| **unit_cost** | DECIMAL(10,2) | Cost to acquire/produce per unit; used in margin calculations. | 45.00, 600.25, 2.50 |
| **weight_kg** | DECIMAL(8,3) | Physical weight in kilograms; used for shipping cost estimation. | 2.500, 0.150, 45.750 |
| **product_status** | VARCHAR(20) | Current lifecycle status; filters active vs. discontinued products. | 'Active', 'Discontinued', 'Out of Stock', 'Unknown' |
| **supplier_id** | BIGINT | Foreign key to supplier dimension; -1 if unassigned. | 100, 205, -1 |
| **launch_date** | DATE | Date product was introduced to market; used for cohort analysis. | 2023-01-15, 2024-06-01 |
| **last_restock_date** | DATE | Most recent date inventory was replenished; indicates freshness. | 2024-11-20, 2024-11-15 |
| **inventory_count** | INT | Current on-hand quantity; used for stock-out risk analysis. | 0, 150, 5000 |
| **_loaded_at** | TIMESTAMP | Exact timestamp when this record was staged; metadata for traceability. | 2024-11-21 14:32:15.123 |

---

## Data Quality & Edge Cases

### Null Handling Strategy
| Field | Handling | Rationale |
|-------|----------|-----------|
| `product_id`, `product_name` | **Filtered out** (WHERE clause) | These are identifiers; records without them are unusable. |
| `supplier_id` | **Replaced with -1** (NVL) | Enables joins and aggregations; -1 is a standard surrogate for "unknown." |
| `category`, `subcategory`, `brand` | **Allowed to be NULL** | These are optional attributes; some products may not have classifications. Downstream queries should handle NULLs explicitly. |
| `launch_date`, `last_restock_date` | **Allowed to be NULL** | Historical data may be incomplete; NULLs indicate missing information rather than errors. |
| `inventory_count` | **Allowed to be NULL** | May indicate data not yet synced from source system; should be treated as "unknown" not "zero." |

### Deduplication Strategy
**No explicit deduplication is performed.** The code assumes:
- The source table `spectrum.raw_products` has a unique constraint on `id`
- Each product appears exactly once in the source
- If duplicates exist in the source, the last one processed by the CREATE AS SELECT will be retained (non-deterministic)

**Risk:** If the source system has duplicate product IDs, this will silently pass through. **Mitigation:** Add a pre-check query or implement a ROW_NUMBER() deduplication if source duplicates are suspected.

### Assumptions About Source Data
1. **Status codes are always 'A', 'D', 'O', or NULL** — If new codes are introduced, they will map to 'Unknown' (safe but may mask data quality issues).
2. **Dates are valid and in the expected format** — CONVERT(DATE, ...) will fail if dates are malformed; no error handling is present.
3. **Numeric fields (price, cost, weight) are always valid decimals** — Invalid values will cause the entire load to fail.
4. **Product IDs are stable** — If a product ID is reused for a different product, the old version is silently overwritten (SCD Type 1 behavior).

### What Could Break If Upstream Data Changes
| Change | Impact | Mitigation |
|--------|--------|-----------|
| New status code introduced (e.g., 'P' for 'Pending') | Maps to 'Unknown'; may confuse analysts | Update CASE statement; add data quality alert |
| Column renamed or removed from source | SQL fails at runtime; entire load fails | Add pre-flight validation; version source schema |
| NULL values appear in `id` or `name` | Silently filtered out; product disappears from analytics | Monitor row counts; alert if filtered rows exceed threshold |
| Duplicate product IDs in source | Non-deterministic behavior; unpredictable which duplicate is retained | Add uniqueness check; implement ROW_NUMBER() deduplication |
| Decimal precision changes (e.g., price with 3 decimals) | Data truncated to 2 decimals; revenue calculations off by fractions of cents | Validate precision in pre-flight checks; adjust DECIMAL(10,3) if needed |
| Date format changes in source | CONVERT fails; entire load fails | Implement TRY_CONVERT or explicit format specification |

---

## Performance Notes

### Distribution & Sorting Strategy
```sql
DISTSTYLE ALL
SORTKEY(product_id)
```

- **DISTSTYLE ALL:** The entire table is replicated to all compute nodes. 
  - **Rationale:** Product dimension is relatively small (typically <1M rows); replication eliminates network shuffles during joins with fact tables, improving query performance.
  - **Trade-off:** Uses more storage; acceptable for slowly-changing master data.
  
- **SORTKEY(product_id):** Table is physically sorted by product_id.
  - **Rationale:** Most joins and lookups use product_id; sorting enables efficient range scans and reduces I/O.
  - **Trade-off:** Slows INSERT/UPDATE operations (not relevant for full refresh); benefits all downstream queries.

### Join Strategy
This is a **single-table SELECT** with no joins, so join performance is not a concern. However, downstream consumers will join this table to fact tables:
- **Expected join key:** `product_id` (indexed via SORTKEY)
- **Join cardinality:** One product dimension row to many fact rows (1:N)
- **Performance implication:** Replication (DISTSTYLE ALL) ensures the dimension is co-located with fact data, enabling efficient broadcast joins.

### Full Table Scan
The entire source table is scanned:
```sql
SELECT ... FROM spectrum.raw_products p WHERE p.id IS NOT NULL AND p.name IS NOT NULL
```
- **Cost:** O(n) where n = number of rows in source
- **Frequency:** Every full refresh cycle (typically daily or hourly)
- **Optimization:** If source table is very large (>100M rows), consider:
  - Incremental load with change data capture (CDC)
  - Filtering by `last_modified_date` to capture only recent changes
  - Partitioning source table by date

### Expensive Operations
- **CAST operations:** Type conversions are CPU-bound but negligible for product dimensions (<1M rows).
- **CASE statement:** Status decoding is O(1) per row; no performance concern.
- **DROP/RENAME:** Metadata operations; negligible cost.

### Table Swap Pattern
```sql
CREATE TABLE staging.stg_raw_products_tmp AS SELECT ...
DROP TABLE IF EXISTS staging.stg_raw_products;
ALTER TABLE staging.stg_raw_products_tmp RENAME TO stg_raw_products;
```
- **Benefit:** Atomic swap prevents queries from hitting a partially-loaded table.
- **Cost:** Requires temporary disk space for both old and new tables during swap.
- **Risk:** If rename fails, the old table is already dropped; no rollback. Mitigated by TRANSACTION wrapper.

### Post-Load Operations
```sql
GRANT SELECT ON staging.stg_raw_products TO GROUP analytics_readers;
ANALYZE staging.stg_raw_products;
```
- **GRANT:** Metadata operation; negligible cost.
- **ANALYZE:** Scans table to update statistics for query planner; O(n) but essential for downstream query optimization. Should complete in seconds for product dimensions.

---

## Dependencies

### Upstream (Must Run Before This Component)
| Component | Reason |
|-----------|--------|
| **spectrum.raw_products** (source table) | This component reads directly from this table. The source must be available and populated before this staging load runs. |
| **Inventory system ETL** | The source table is populated by the inventory system's ETL pipeline; that pipeline must complete successfully before this component runs. |

### Downstream (Depends on This Component's Output)
| Component | Usage |
|-----------|-------|
| **marts.dim_products** | Consumes `staging.stg_raw_products` to build the product dimension for the analytics data warehouse. |
| **marts.fct_sales** | Joins to `staging.stg_raw_products` (or its downstream dim) to add product context to sales transactions. |
| **marts.fct_inventory** | Uses product attributes (category, brand, weight) for inventory analysis and forecasting. |
| **reporting.product_performance_dashboard** | Queries the staged product data to display product hierarchies, pricing, and status in dashboards. |
| **analytics.product_cohort_analysis** | Uses `launch_date` to segment products by cohort; depends on accurate date conversion. |
| **data_quality_checks.product_dimension_validation** | Monitors row counts, null rates, and status distributions to detect upstream data quality issues. |

### External Dependencies
| Dependency | Type | Purpose |
|------------|------|---------|
| **analytics_readers** (database group) | Access control | GRANT statement assumes this group exists; if it doesn't, the GRANT will fail. |
| **Redshift cluster** | Infrastructure | Assumes Redshift is available and the staging schema exists. |
| **Spectrum** (external schema) | Data source | Assumes Spectrum is configured to read from the inventory system's data lake or external database. |

### Orchestration Assumptions
- **Scheduler:** Not specified in code; assume Airflow, dbt, or similar orchestration tool triggers this SQL.
- **Error handling:** The TRANSACTION wrapper provides rollback on failure, but the orchestrator must detect and handle failures.
- **Retry logic:** Not implemented; orchestrator should implement retry policy for transient failures.

---

## Additional Recommendations

### Data Quality Checks (Pre-Load)
Consider adding pre-flight validation before the main load:
```sql
-- Check for duplicates in source
SELECT id, COUNT(*) FROM spectrum.raw_products GROUP BY id HAVING COUNT(*) > 1;

-- Check for unexpected status codes
SELECT DISTINCT status FROM spectrum.raw_products WHERE status NOT IN ('A', 'D', 'O');

-- Check for invalid dates
SELECT * FROM spectrum.raw_products WHERE launch_date > GETDATE();
```

### Monitoring & Alerting
- **Row count comparison:** Alert if staged row count differs by >5% from previous load (indicates data quality issue).
- **NULL rate monitoring:** Track % of NULL values per column; alert if rates spike.
- **Load duration:** Monitor how long the full refresh takes; alert if it exceeds SLA.

### Future Enhancements
1. **Incremental load:** Implement CDC-based incremental load to reduce full refresh overhead.
2. **SCD Type 2:** If historical product attributes need to be tracked (e.g., price changes), implement SCD Type 2 with effective dates.
3. **Data validation:** Add explicit validation of DECIMAL precision and date formats before CAST operations.
4. **Partitioning:** If product table grows beyond 100M rows, consider partitioning by category or launch_date.