# staging/stg_raw_products.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (full refresh)
- **Schedule:** Not specified in code; infer from orchestration metadata
- **Owner:** Not specified in code; infer from data governance documentation

---

## Purpose

This component ingests and standardizes the raw product catalog from the inventory management system into a cleaned, consistently-typed staging table. It serves as the single source of truth for all downstream product dimensions, reporting, and analytics by normalizing data types, decoding status codes, and applying basic data quality filters. The output is consumed by dimensional modeling layers (e.g., `dim_products`) and operational dashboards that require a reliable, up-to-date product master.

---

## Inputs

| Source | Purpose | Notes |
|--------|---------|-------|
| **spectrum.raw_products** | Raw product catalog from the inventory system | Contains denormalized product attributes (SKU, pricing, categorization, status codes). Assumed to be a full daily or event-driven extract. No incremental logic is applied; this component performs a full refresh. |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **staging.stg_raw_products** | Cleaned, standardized product master with 15 columns including product IDs, SKUs, pricing, categorization, and status flags. One row per product. | `dim_products` (dimensional layer), product analytics dashboards, inventory reports, pricing analysis, and any downstream fact tables that require product context (e.g., `fct_sales`, `fct_inventory`). |

---

## Key Business Logic

### 1. **Type Casting & Standardization**
- All columns are explicitly cast to target data types (BIGINT, VARCHAR, DECIMAL, DATE).
- **Why:** Ensures consistency across the data warehouse and prevents type coercion errors in downstream joins and aggregations. Raw source data may arrive as strings or mixed types.

### 2. **Status Code Decoding**
```
CASE
    WHEN p.status = 'A' THEN 'Active'
    WHEN p.status = 'D' THEN 'Discontinued'
    WHEN p.status = 'O' THEN 'Out of Stock'
    ELSE 'Unknown'
END AS product_status
```
- **Why:** Transforms single-character inventory system codes into human-readable business terms. Enables non-technical stakeholders to understand product lifecycle state. The `ELSE 'Unknown'` clause handles unexpected status values gracefully without failing the load.

### 3. **Supplier ID Null Handling**
```
NVL(p.supplier_id, -1) AS supplier_id
```
- **Why:** Replaces NULL supplier IDs with a sentinel value (-1) to avoid NULL-related join issues downstream. This is a common pattern for optional foreign keys; -1 signals "no supplier assigned" rather than "unknown."

### 4. **Data Quality Filtering**
```
WHERE p.id IS NOT NULL
  AND p.name IS NOT NULL
```
- **Why:** Excludes incomplete product records that lack a primary identifier or name. These records cannot be reliably joined or identified downstream and would create data quality issues in fact tables.

### 5. **Load Timestamp**
```
GETDATE() AS _loaded_at
```
- **Why:** Captures the exact time the staging table was refreshed. Enables downstream processes to detect stale data and supports audit trails for compliance and debugging.

### 6. **SCD Type 1 Strategy (Full Refresh)**
- The entire table is dropped and recreated on each run (`DROP TABLE IF EXISTS staging.stg_raw_products_tmp`).
- **Why:** Implements SCD Type 1 (overwrite) semantics—only the latest product attributes are retained. Historical changes are not tracked at this layer. This is appropriate for a master data table where the current state is the source of truth.

---

## Column Descriptions

| Column Name | Data Type | Description | Example Values |
|-------------|-----------|-------------|-----------------|
| **product_id** | BIGINT | Unique product identifier, cast from source system ID. Primary key. | 1001, 5432, 999999 |
| **sku** | VARCHAR(50) | Stock Keeping Unit—unique product code used in inventory and sales systems. | 'SKU-12345', 'PROD-ABC-001' |
| **product_name** | VARCHAR(200) | Human-readable product name. | 'Wireless Bluetooth Headphones', 'Office Chair - Ergonomic' |
| **category** | VARCHAR(100) | Top-level product category for segmentation and reporting. | 'Electronics', 'Furniture', 'Apparel' |
| **subcategory** | VARCHAR(100) | Secondary product classification for finer-grained analysis. | 'Audio Equipment', 'Office Seating', 'Outerwear' |
| **brand** | VARCHAR(100) | Manufacturer or brand name. Used for brand-level reporting and filtering. | 'Sony', 'Herman Miller', 'Nike' |
| **unit_price** | DECIMAL(10,2) | Current retail or list price per unit. Used in revenue calculations and pricing analysis. | 99.99, 1250.00, 15.50 |
| **unit_cost** | DECIMAL(10,2) | Cost to acquire or manufacture the product. Used for margin and profitability analysis. | 45.00, 600.00, 8.25 |
| **weight_kg** | DECIMAL(8,3) | Product weight in kilograms. Used for shipping cost estimation and logistics planning. | 0.250, 15.500, 2.100 |
| **product_status** | VARCHAR(20) | Decoded product lifecycle state. Indicates whether a product is actively sold, discontinued, or out of stock. | 'Active', 'Discontinued', 'Out of Stock', 'Unknown' |
| **supplier_id** | BIGINT | Foreign key to supplier master. -1 indicates no assigned supplier. Used for supplier-level analysis and procurement tracking. | 101, 205, -1 |
| **launch_date** | DATE | Date the product was first introduced to the catalog. Used for product age analysis and cohort studies. | 2023-01-15, 2024-06-20 |
| **last_restock_date** | DATE | Most recent date inventory was replenished. Indicates product freshness and demand patterns. | 2024-11-10, 2024-11-05 |
| **inventory_count** | INT | Current on-hand inventory quantity. Used for stock level reporting and availability analysis. | 0, 150, 5000 |
| **_loaded_at** | TIMESTAMP | Timestamp when this record was loaded into the staging table. Used for freshness monitoring and audit trails. | 2024-11-15 14:32:05, 2024-11-16 02:15:00 |

---

## Data Quality & Edge Cases

### Null Handling
| Column | Null Strategy | Rationale |
|--------|---------------|-----------|
| **product_id, product_name** | Filtered out (WHERE clause) | These are required identifiers; records without them cannot be reliably used downstream. |
| **supplier_id** | Replaced with -1 (NVL) | Indicates optional relationship; -1 is a sentinel value that avoids NULL join issues. |
| **category, subcategory, brand** | Allowed to be NULL | May be unknown for some products; downstream processes should handle NULLs gracefully. |
| **launch_date, last_restock_date** | Allowed to be NULL | Not all products have known launch dates; NULL is semantically correct. |
| **inventory_count** | Allowed to be NULL | May indicate data unavailability; downstream should treat NULL as "unknown" rather than zero. |

### Deduplication Strategy
- **No explicit deduplication is performed.** The code assumes `spectrum.raw_products` contains one row per product_id.
- **Risk:** If the source system contains duplicate product_ids, this component will pass duplicates downstream, causing inflated row counts and join issues.
- **Mitigation:** Add a deduplication step (e.g., `ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY updated_at DESC)`) if source data is known to contain duplicates.

### Assumptions About Source Data
1. **product_id is unique** — No validation is performed; duplicates will propagate.
2. **Status codes are limited to {A, D, O}** — Unexpected values default to 'Unknown' without alerting.
3. **Dates are valid** — CONVERT(DATE, ...) will fail if dates are malformed; no error handling is in place.
4. **Numeric fields (price, cost, weight) are valid decimals** — Invalid values will cause the load to fail.
5. **The source table is available and readable** — No retry logic or fallback is implemented.

### What Could Break
| Scenario | Impact | Mitigation |
|----------|--------|-----------|
| Source table contains duplicate product_ids | Duplicate rows in staging table; downstream joins produce Cartesian products | Add ROW_NUMBER deduplication; validate uniqueness in source system |
| Malformed dates (e.g., '2024-13-45') | Load fails with CONVERT error | Add TRY_CONVERT or date validation; quarantine bad records |
| NULL product_id or product_name | Rows silently filtered out; data loss not visible | Add logging to track filtered row counts; alert if threshold exceeded |
| Unexpected status codes | Silently mapped to 'Unknown'; business logic may not account for new statuses | Implement data quality checks; alert on new status values |
| Numeric overflow (e.g., price > 9999999.99) | Load fails due to DECIMAL(10,2) constraint | Validate source data ranges; adjust precision if needed |
| Source table unavailable | Load fails; no fallback to previous version | Implement error handling; consider keeping previous version as fallback |

---

## Performance Notes

### Distribution & Sort Keys
```
DISTSTYLE ALL
SORTKEY(product_id)
```
- **DISTSTYLE ALL:** The entire table is replicated to all compute nodes. 
  - **Rationale:** Product master is small (typically < 1M rows) and accessed by many downstream queries. Replication avoids network shuffles during joins.
  - **Trade-off:** Increases storage overhead; acceptable for small reference tables.
  
- **SORTKEY(product_id):** Table is physically sorted by product_id.
  - **Rationale:** Most downstream joins use product_id; sorting enables efficient range scans and reduces I/O.
  - **Impact:** Improves join performance with `fct_sales`, `fct_inventory`, and other fact tables.

### Join Strategy
- **No joins are performed in this component.** All data comes from a single source table.
- **Implication:** This is a simple, fast transformation with minimal CPU overhead.

### Full Table Scans
- The WHERE clause filters on product_id and product_name, neither of which are indexed in the source system (spectrum.raw_products).
- **Impact:** A full scan of spectrum.raw_products is required. For large catalogs (> 10M products), this could be slow.
- **Optimization:** If source data is partitioned by date or status, add partition pruning to the WHERE clause.

### Expensive Operations
- **CAST operations:** Type conversions are generally fast but can be slow for large text fields (e.g., VARCHAR(200)). Negligible impact for product names.
- **CASE statement:** The status decoding CASE statement is evaluated for every row. Negligible overhead.
- **GETDATE():** Evaluated once per load; no per-row overhead.

### Table Swap (Atomic Refresh)
```
DROP TABLE IF EXISTS staging.stg_raw_products_tmp;
ALTER TABLE staging.stg_raw_products_tmp RENAME TO stg_raw_products;
```
- **Rationale:** Ensures zero downtime during refresh. New data is built in a temporary table, then atomically swapped into place.
- **Benefit:** Downstream queries are never interrupted; they continue reading the old table until the swap completes.

### Estimated Load Time
- **For 1M products:** ~5-10 seconds (assuming spectrum.raw_products is accessible and well-indexed).
- **For 10M products:** ~30-60 seconds.
- **Bottleneck:** Network I/O from spectrum (external catalog) to staging schema.

---

## Dependencies

### Upstream
| Component | Type | Purpose | Criticality |
|-----------|------|---------|-------------|
| **spectrum.raw_products** | External table (Redshift Spectrum) | Source of raw product data from inventory system | **CRITICAL** — Load fails if unavailable or schema changes |

### Downstream
| Component | Type | Purpose | Dependency Type |
|-----------|------|---------|-----------------|
| **dim_products** | Dimensional table | Consumes stg_raw_products to build the product dimension with SCD Type 2 tracking | **HARD** — dim_products must run after this component completes |
| **fct_sales** | Fact table | Joins to stg_raw_products for product attributes (category, brand, pricing) | **HARD** — Sales fact table requires current product master |
| **fct_inventory** | Fact table | Uses product_id and inventory_count for stock level analysis | **HARD** — Inventory fact table depends on current inventory_count |
| **Product Analytics Dashboard** | BI/Reporting | Queries stg_raw_products directly for product catalog, pricing, and status reporting | **SOFT** — Dashboard can tolerate slight staleness; refreshes on schedule |
| **Pricing Analysis Reports** | Ad-hoc analysis | Uses unit_price and unit_cost for margin and profitability calculations | **SOFT** — Analysts may query directly; not part of critical path |

### External
| System | Purpose | Notes |
|--------|---------|-------|
| **Inventory Management System** | Source of raw product data | Data is extracted to spectrum.raw_products via daily ETL (not shown in this code). |
| **Redshift Spectrum** | External table catalog | Provides access to raw_products; requires S3 connectivity and Glue metadata. |
| **Redshift Cluster** | Compute & storage | This script runs on the Redshift cluster; requires sufficient disk space for temporary table. |

### Execution Order
```
1. Inventory System → spectrum.raw_products (external ETL, not shown)
2. spectrum.raw_products → staging.stg_raw_products (THIS COMPONENT)
3. staging.stg_raw_products → dim_products (dimensional layer)
4. dim_products + fct_sales/fct_inventory → Analytics dashboards
```

---

## Operational Considerations

### Monitoring & Alerting
- **Row count:** Alert if row count drops > 10% or increases > 50% (indicates data quality issue).
- **Load time:** Alert if execution time exceeds 2x baseline (indicates performance degradation).
- **NULL rates:** Monitor percentage of NULLs in key columns (category, brand, launch_date); alert if > threshold.
- **Status distribution:** Track count of 'Unknown' status values; alert if > 1% (indicates new status codes in source).

### Maintenance
- **Vacuum & Analyze:** The ANALYZE command at the end updates table statistics for the query optimizer. Consider running VACUUM periodically to reclaim space from deleted rows (though full refresh mitigates this).
- **Permissions:** GRANT SELECT to analytics_readers ensures BI tools and analysts can query the table.

### Rollback Strategy
- If data quality issues are detected downstream, the previous version of stg_raw_products is lost (full refresh overwrites it).
- **Recommendation:** Implement a backup or versioning strategy (e.g., keep `stg_raw_products_v1`, `stg_raw_products_v2`) to enable rollback.