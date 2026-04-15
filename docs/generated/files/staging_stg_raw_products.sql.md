# staging/stg_raw_products.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (full refresh)
- **Schedule:** Not specified in code; infer from orchestration metadata
- **Owner:** Not specified in code; infer from team documentation
- **SCD Strategy:** Type 1 (overwrite with latest values; no historical tracking)

---

## Purpose

This component ingests the raw product catalog from the inventory management system and applies standardized data cleaning, type casting, and business rule transformations. It serves as the single source of truth for product master data in the analytics layer, enabling downstream reporting and dimensional modeling while ensuring data consistency across all analytics consumers.

The staging table is consumed by analytics teams, BI tools, and dimensional modeling processes that require a clean, standardized product dimension.

---

## Inputs

| Source | Purpose | Criticality |
|--------|---------|-------------|
| **spectrum.raw_products** | Raw product catalog from the inventory system, containing product identifiers, attributes (SKU, name, category, pricing), and operational metadata (status, supplier, restock dates, inventory counts). This is the authoritative source for all product master data. | Critical |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **staging.stg_raw_products** | Cleaned and standardized product master data with 14 columns including product identifiers, hierarchical categorization, pricing/cost, physical attributes, status, and load timestamp. Distributed across all nodes (DISTSTYLE ALL) and sorted by product_id for optimal join performance. | Fact tables (orders, inventory transactions), dimensional models (dim_products), reporting views, BI dashboards, product analytics, pricing analysis |

---

## Key Business Logic

### 1. **Type Casting & Standardization**
All columns are explicitly cast to target data types (BIGINT, VARCHAR, DECIMAL, DATE). This ensures:
- Consistent data types across the analytics layer
- Prevention of implicit type coercion errors in downstream joins
- Predictable numeric precision for financial calculations (DECIMAL(10,2) for prices, DECIMAL(8,3) for weight)

### 2. **Status Code Decoding**
```
Status codes from source → Human-readable labels
'A' → 'Active'
'D' → 'Discontinued'
'O' → 'Out of Stock'
NULL/other → 'Unknown'
```
**Why:** Source system uses abbreviated codes; analytics consumers expect descriptive labels for filtering and reporting. The CASE statement with ELSE clause prevents null status values from breaking downstream logic.

### 3. **Supplier ID Null Handling**
```
NVL(p.supplier_id, -1) AS supplier_id
```
**Why:** Replaces NULL supplier IDs with -1 (a sentinel value representing "no supplier assigned"). This prevents:
- NULL values from breaking foreign key joins in fact tables
- Ambiguity in GROUP BY operations
- Loss of product records in inner joins with supplier dimensions

### 4. **Date Conversion**
Launch date and last restock date are converted from source format (likely DATETIME or STRING) to DATE type. This:
- Removes time components for cleaner date-based filtering
- Ensures consistency with date dimensions
- Reduces storage footprint vs. DATETIME

### 5. **Data Quality Filter**
```
WHERE p.id IS NOT NULL
  AND p.name IS NOT NULL
```
**Why:** Enforces minimum data quality standards by excluding:
- Products without identifiers (cannot be uniquely tracked)
- Products without names (unusable in reporting/UI)
- These are business-critical fields; missing values indicate data corruption upstream

### 6. **Load Timestamp**
```
GETDATE() AS _loaded_at
```
**Why:** Captures the exact time this refresh occurred. Enables:
- Audit trails for data freshness
- Debugging of stale data issues
- SLA monitoring (e.g., "data is never older than 24 hours")

### 7. **Full Refresh Strategy (SCD Type 1)**
The entire table is dropped and recreated each run (no incremental logic). This:
- Simplifies logic (no merge/upsert complexity)
- Ensures all historical corrections from source are reflected
- Assumes source system is authoritative and complete
- **Trade-off:** No historical tracking; previous values are lost

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **product_id** | BIGINT | Unique product identifier from source system. Primary key for this table. | 1001, 5432, 999999 |
| **sku** | VARCHAR(50) | Stock Keeping Unit—human-readable product code used in operations and inventory systems. | 'WIDGET-001', 'GADGET-XL-BLK' |
| **product_name** | VARCHAR(200) | Full product name for display in reports and BI tools. | 'Industrial Widget Pro', 'Compact Gadget XL' |
| **category** | VARCHAR(100) | Top-level product hierarchy for segmentation and reporting. | 'Electronics', 'Office Supplies', 'Hardware' |
| **subcategory** | VARCHAR(100) | Secondary product hierarchy for detailed segmentation. | 'Laptops', 'Keyboards', 'Fasteners' |
| **brand** | VARCHAR(100) | Manufacturer or brand name. Used for brand-level reporting and margin analysis. | 'Acme Corp', 'TechBrand Inc' |
| **unit_price** | DECIMAL(10,2) | Current selling price per unit in company currency. Used in revenue calculations. | 99.99, 1250.00 |
| **unit_cost** | DECIMAL(10,2) | Current cost per unit (COGS). Used in margin and profitability analysis. | 45.50, 600.00 |
| **weight_kg** | DECIMAL(8,3) | Physical weight in kilograms. Used for shipping cost estimation and logistics planning. | 2.500, 0.125 |
| **product_status** | VARCHAR(20) | Operational status decoded from source codes. Filters active vs. discontinued products in reporting. | 'Active', 'Discontinued', 'Out of Stock', 'Unknown' |
| **supplier_id** | BIGINT | Foreign key to supplier dimension. -1 indicates no assigned supplier. Used for supplier-level analysis. | 42, 100, -1 |
| **launch_date** | DATE | Date product was introduced to market. Used for product age analysis and cohort reporting. | 2023-01-15, 2024-06-01 |
| **last_restock_date** | DATE | Most recent date inventory was replenished. Indicates product freshness and demand patterns. | 2024-12-10, 2024-11-28 |
| **inventory_count** | INT | Current on-hand inventory quantity. Used for stock-out risk analysis and inventory valuation. | 150, 0, 5000 |
| **_loaded_at** | TIMESTAMP | Timestamp when this record was loaded into staging. Enables freshness monitoring and audit trails. | 2024-12-15 14:30:22, 2024-12-16 02:15:45 |

---

## Data Quality & Edge Cases

### Null Handling Strategy

| Column | Null Behavior | Rationale |
|--------|---------------|-----------|
| **product_id, product_name** | Filtered out (WHERE clause) | These are business-critical identifiers; records without them are unusable |
| **supplier_id** | Replaced with -1 | Enables joins without losing product records; -1 is a sentinel value |
| **category, subcategory, brand** | Passed through as NULL | May be legitimately unknown for some products; downstream logic should handle gracefully |
| **launch_date, last_restock_date** | Passed through as NULL | May not apply to all product types; NULL is semantically meaningful |
| **product_status** | Defaults to 'Unknown' | CASE ELSE clause ensures no NULL status values reach downstream |

### Deduplication Strategy
**None.** This component assumes the source table (spectrum.raw_products) contains one row per product_id. If duplicates exist upstream, they will be replicated here. 

**Risk:** If source system has duplicate product_id values, the final table will contain duplicates, breaking downstream joins and aggregations.

**Mitigation:** Add a deduplication step if source duplicates are suspected:
```sql
ROW_NUMBER() OVER (PARTITION BY p.id ORDER BY p.updated_at DESC) AS rn
...
WHERE rn = 1
```

### Key Assumptions About Upstream Data

1. **product_id is unique** — No duplicate product identifiers in source
2. **Status codes are limited to {A, D, O}** — Any other value maps to 'Unknown'
3. **Dates are valid** — CONVERT(DATE, ...) will fail if source contains malformed dates
4. **Numeric fields are numeric** — CAST to DECIMAL/BIGINT will fail on non-numeric strings
5. **Source table is complete** — Full refresh assumes all current products are present each run
6. **No late-arriving data** — Data is available immediately; no delayed updates expected

### What Could Break

| Scenario | Impact | Symptom |
|----------|--------|---------|
| Source contains duplicate product_id values | Duplicate rows in staging table | Downstream fact tables have inflated row counts; joins produce Cartesian products |
| Malformed dates in launch_date or last_restock_date | Query fails with conversion error | Pipeline fails; no data loaded |
| Non-numeric values in price/cost columns | Query fails with CAST error | Pipeline fails; no data loaded |
| supplier_id contains values outside expected range | Incorrect foreign key joins | Supplier dimension joins fail or produce unexpected nulls |
| Source table is unavailable or truncated | Staging table is dropped but not recreated | Downstream jobs fail; analytics goes dark |
| New status codes introduced (e.g., 'P' for 'Pending') | Status maps to 'Unknown' | Reporting shows unexpected 'Unknown' values; business logic breaks |

---

## Performance Notes

### Distribution & Sorting Strategy

```sql
DISTSTYLE ALL
SORTKEY(product_id)
```

**DISTSTYLE ALL (Replicate to All Nodes):**
- **Why:** Product dimension is small (typically <1M rows) and accessed by nearly every fact table join
- **Benefit:** Eliminates network traffic for joins; each node has full copy
- **Trade-off:** Uses more storage; slower INSERT/UPDATE operations (must update all nodes)
- **Assumption:** Product catalog is small enough to fit in memory on all nodes

**SORTKEY(product_id):**
- **Why:** product_id is the primary join key in downstream fact tables (orders, inventory transactions)
- **Benefit:** Sorts data on disk; range scans and joins are faster
- **Trade-off:** Slower initial load; maintenance overhead

### Join Implications

Downstream fact tables will perform **broadcast joins** (product dimension replicated to all nodes):
```sql
SELECT f.order_id, f.quantity, p.product_name, p.unit_price
FROM fact_orders f
JOIN staging.stg_raw_products p ON f.product_id = p.product_id
```
- **No network shuffle required** — each node has full product table
- **Optimal for small dimensions** — product catalog is ideal candidate
- **Risk:** If product table grows to >100M rows, DISTSTYLE ALL becomes inefficient

### Expensive Operations

1. **Full Table Scan (CREATE TABLE AS SELECT):**
   - Reads entire spectrum.raw_products table
   - No predicate pushdown to source system
   - **Mitigation:** If source is very large, consider incremental load with change data capture

2. **Type Casting:**
   - CAST operations on every column
   - Minimal overhead for small table
   - **Risk:** If source has millions of rows with mixed types, casting becomes CPU-intensive

3. **ANALYZE Command:**
   - Computes table statistics for query optimizer
   - Necessary for accurate query plans
   - **Cost:** Scans entire table; can take minutes on large tables

### Potential Bottlenecks

- **Source system availability:** If spectrum.raw_products is slow or locked, this job blocks
- **Disk I/O:** Full refresh requires writing entire table to disk
- **Network:** If DISTSTYLE ALL replication is slow, load time increases

---

## Dependencies

### Upstream (Must Run Before This Component)

| Component | Reason |
|-----------|--------|
| **spectrum.raw_products** (source system extract) | This component reads directly from the source table; it must be populated first |
| **Inventory system ETL** | The source system must have completed its data load before this staging job runs |

### Downstream (Components That Depend on This Output)

| Component | Usage |
|-----------|-------|
| **dim_products** (dimensional model) | Consumes stg_raw_products to build the product dimension; used in all fact tables |
| **fact_orders** | Joins on product_id to enrich order records with product attributes (name, category, price) |
| **fact_inventory_transactions** | Joins to track inventory movements by product |
| **rpt_product_performance** | Reporting view that aggregates sales/margin by product, category, brand |
| **BI dashboards** (Tableau, Looker, etc.) | Direct or indirect consumption via dimensional models |
| **Product analytics** | Ad-hoc queries on product catalog, pricing analysis, SKU rationalization |

### External Dependencies

| Dependency | Type | Purpose |
|------------|------|---------|
| **spectrum schema** | Redshift external schema | Provides access to raw_products table from source system |
| **staging schema** | Redshift schema | Target location for staging tables |
| **analytics_readers group** | Redshift user group | Granted SELECT permissions on output table |
| **Orchestration system** (Airflow, dbt, etc.) | Scheduler | Triggers this job on a defined schedule |

---

## Maintenance & Monitoring

### Key Metrics to Monitor

- **Load duration:** Track if full refresh time increases (indicates upstream data growth)
- **Row count:** Alert if product count drops >10% (potential data quality issue)
- **NULL rates:** Monitor % of NULL values in key columns (category, brand, etc.)
- **Freshness:** Ensure _loaded_at is recent; alert if stale

### Common Issues & Resolutions

| Issue | Cause | Resolution |
|-------|-------|-----------|
| "Table does not exist" error in downstream jobs | Staging job failed; table was dropped but not recreated | Check staging job logs; re-run if safe |
| Duplicate product_ids in reports | Source system has duplicates | Add ROW_NUMBER() deduplication; investigate source |
| "Invalid conversion" error | Malformed date or numeric value in source | Validate source data; add error handling |
| Slow joins in fact tables | DISTSTYLE ALL replication is slow | Monitor table size; consider switching to EVEN distribution if >100M rows |

---

## Related Documentation

- **Source System:** [Inventory System Data Dictionary]
- **Dimensional Model:** [dim_products.sql]
- **Fact Tables:** [fact_orders.sql], [fact_inventory_transactions.sql]
- **Data Governance:** [Product Master Data Standards]
- **SCD Strategy:** [Slowly Changing Dimensions Implementation Guide]