# staging/stg_raw_products.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (full refresh)
- **Schedule:** Not specified in code; infer from orchestration layer
- **Owner:** Not specified in code; recommend adding to header comments

---

## Purpose

This component ingests and standardizes the raw product catalog from the inventory management system into a cleaned, consistently-typed staging table. It serves as the single source of truth for all downstream product dimensions, analytics, and reporting by normalizing data types, decoding status codes, and applying basic data quality filters. The output is consumed by dimensional modeling layers (e.g., `dim_products`) and analytical queries that require a reliable, deduplicated product master.

---

## Inputs

| Source | Purpose | Criticality |
|--------|---------|-------------|
| **spectrum.raw_products** | Raw product records from the inventory system, including SKU, pricing, categorization, and stock status. This component depends on this table being available and containing the complete current product catalog. | Critical |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **staging.stg_raw_products** | Cleaned, type-cast product records with decoded status values, surrogate keys, and load timestamps. Serves as the authoritative staging layer for product data. | `dim_products` (dimensional model), analytics views, product reporting dashboards, inventory analysis queries |

---

## Key Business Logic

### 1. **Type Casting & Standardization**
- All numeric identifiers (`id`, `supplier_id`) cast to `BIGINT` to ensure consistency across the data warehouse and prevent overflow issues in downstream joins.
- Prices and costs cast to `DECIMAL(10,2)` to preserve financial precision (cents) and prevent floating-point rounding errors in margin calculations.
- Weight cast to `DECIMAL(8,3)` to support logistics and shipping cost calculations.
- Text fields cast to fixed-length `VARCHAR` to enforce schema consistency and optimize storage/compression.

### 2. **Status Code Decoding**
- Raw single-character status codes (`A`, `D`, `O`) are decoded into human-readable values (`Active`, `Discontinued`, `Out of Stock`). This improves usability for analysts and reduces downstream decoding logic.
- Unknown/unmapped status values default to `'Unknown'` rather than `NULL` to preserve data visibility and flag potential upstream data quality issues.

### 3. **Null Handling for Foreign Keys**
- `supplier_id` is coalesced to `-1` when null, creating a surrogate "unknown supplier" key. This prevents null-join issues in downstream dimensional joins and ensures every product record has a valid supplier reference.

### 4. **Date Normalization**
- `launch_date` and `last_restock_date` are converted from raw timestamp/string formats to `DATE` type for consistency and to simplify date-based filtering in analytics queries.

### 5. **Data Quality Filtering**
- Records with `NULL product_id` or `NULL product_name` are excluded via the `WHERE` clause. These are considered incomplete/invalid and should not propagate downstream.
- This filtering assumes that `id` and `name` are mandatory attributes; if the business allows products without names, this logic must be revisited.

### 6. **Load Timestamp**
- `_loaded_at` captures the exact time the record was staged using `GETDATE()`, enabling audit trails, late-arriving fact detection, and SCD Type 1 change tracking.

### 7. **SCD Type 1 Strategy**
- The full refresh approach (drop and recreate) implements SCD Type 1: historical changes are overwritten, not preserved. This is appropriate for a product master where the latest state is authoritative (e.g., current price, current status).
- If historical tracking is needed (e.g., price history), this logic must be changed to SCD Type 2 (add effective dates and flags).

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **product_id** | BIGINT | Unique surrogate key for the product, sourced from the inventory system. Used for all downstream joins. | `1001`, `5432`, `999999` |
| **sku** | VARCHAR(50) | Stock Keeping Unit—the business-facing product identifier used in orders and inventory systems. | `SKU-2024-001`, `WIDGET-XL-BLU` |
| **product_name** | VARCHAR(200) | Human-readable product name for reporting and analytics. | `Ergonomic Office Chair`, `USB-C Cable 2m` |
| **category** | VARCHAR(100) | Top-level product classification for segmentation and rollup analysis. | `Furniture`, `Electronics`, `Apparel` |
| **subcategory** | VARCHAR(100) | Secondary product classification for more granular analysis. | `Office Seating`, `Cables & Adapters`, `Outerwear` |
| **brand** | VARCHAR(100) | Brand/manufacturer name for brand-level reporting and margin analysis. | `Herman Miller`, `Belkin`, `Nike` |
| **unit_price** | DECIMAL(10,2) | Current selling price per unit in the base currency. Used in revenue calculations and pricing analysis. | `299.99`, `12.50`, `0.99` |
| **unit_cost** | DECIMAL(10,2) | Current cost per unit (COGS). Used for margin, profitability, and inventory valuation. | `150.00`, `5.25`, `0.35` |
| **weight_kg** | DECIMAL(8,3) | Product weight in kilograms. Used for shipping cost estimation and logistics planning. | `15.500`, `0.250`, `2.100` |
| **product_status** | VARCHAR(20) | Decoded product lifecycle status. Filters active vs. discontinued products in analytics. | `Active`, `Discontinued`, `Out of Stock`, `Unknown` |
| **supplier_id** | BIGINT | Foreign key to the supplier dimension. Coalesced to `-1` if unknown. Used for supplier-level analysis and sourcing audits. | `42`, `101`, `-1` (unknown) |
| **launch_date** | DATE | Date the product was first introduced to the catalog. Used for product age analysis and new product reporting. | `2024-01-15`, `2023-06-01` |
| **last_restock_date** | DATE | Most recent date inventory was replenished. Indicates product freshness and demand patterns. | `2024-12-10`, `2024-11-28` |
| **inventory_count** | INT | Current on-hand inventory quantity. Used for stock-out risk analysis and inventory turnover. | `150`, `0`, `5000` |
| **_loaded_at** | TIMESTAMP | Timestamp when the record was staged. Enables audit trails and change detection. | `2024-12-11 14:32:15.123` |

---

## Data Quality & Edge Cases

### Null Handling
| Field | Behavior | Rationale |
|-------|----------|-----------|
| `product_id`, `product_name` | **Excluded** (WHERE clause) | These are mandatory identifiers; records without them are incomplete and should not propagate. |
| `supplier_id` | **Coalesced to -1** | Prevents null-join failures; ensures every product has a valid supplier reference (even if "unknown"). |
| `category`, `subcategory`, `brand` | **Allowed to be NULL** | These are optional attributes; null values are preserved to flag incomplete master data without losing the product record. |
| `launch_date`, `last_restock_date` | **Allowed to be NULL** | Date fields may be null for legacy products or those without recorded dates; nulls are preserved. |
| `inventory_count` | **Allowed to be NULL** | May be null if inventory is not tracked for certain product types. |

### Deduplication Strategy
- **No explicit deduplication** is performed. The code assumes `spectrum.raw_products` contains one row per unique `product_id`.
- **Risk:** If the source system contains duplicate product records (e.g., due to ETL bugs or data entry errors), duplicates will propagate to staging.
- **Recommendation:** Add a `ROW_NUMBER()` window function to deduplicate by `product_id`, ordering by `_loaded_at DESC` or a source-system update timestamp, if duplicates are suspected.

### Assumptions About Source Data
1. **Uniqueness:** `spectrum.raw_products.id` is unique and non-null for all valid products.
2. **Status codes:** Only values `'A'`, `'D'`, `'O'` are expected; any other value triggers the `'Unknown'` default.
3. **Data types:** Source columns are compatible with the target `CAST` operations (e.g., `price` is numeric or numeric-string).
4. **Completeness:** `name` is always populated for valid products.
5. **Freshness:** The source table is refreshed regularly (schedule not specified); stale data is not expected.

### Potential Failure Points
| Scenario | Impact | Mitigation |
|----------|--------|-----------|
| Source table `spectrum.raw_products` is unavailable or dropped | Job fails; no new staging data loaded. | Add error handling and alerting; document SLA for source system availability. |
| `price` or `cost` contains non-numeric values | `CAST` fails; entire job aborts. | Add data validation in the source system or add `TRY_CAST` with null fallback. |
| `supplier_id` contains values outside the valid supplier dimension | Foreign key constraint violation in downstream joins. | Add a validation query to check for orphaned supplier IDs; consider adding a `supplier_id` dimension check. |
| Duplicate `product_id` values in source | Duplicates propagate to staging; downstream joins may produce incorrect row counts. | Add deduplication logic (see above). |
| Status code changes in source system (e.g., new code `'S'` for "Seasonal") | New codes map to `'Unknown'`, potentially hiding data quality issues. | Maintain a mapping table for status codes; add monitoring for unmapped values. |
| `launch_date` or `last_restock_date` contains invalid date strings | `CONVERT(DATE, ...)` fails. | Use `TRY_CONVERT` or add upstream validation. |

---

## Performance Notes

### Distribution & Sorting Strategy
- **DISTSTYLE ALL:** The entire table is replicated to all compute nodes. This is appropriate for a relatively small dimension table (product master) that is frequently joined. Avoids network shuffles during joins.
  - **Trade-off:** Increases storage overhead; suitable only if the table is <100GB. If `spectrum.raw_products` grows significantly, consider `DISTSTYLE KEY (product_id)` to distribute by the join key.
- **SORTKEY(product_id):** Rows are physically sorted by `product_id` on disk. This accelerates range scans and joins on `product_id`, which is the primary join key downstream.
  - **Benefit:** Improves query performance for joins and filters on `product_id`.
  - **Cost:** Slightly increases load time due to sorting; negligible for full refreshes.

### Full Refresh Overhead
- **DROP and CREATE:** The entire table is dropped and recreated on each run. This is a full refresh strategy.
  - **Advantage:** Simple, no merge logic; guarantees consistency and removes stale records.
  - **Disadvantage:** Expensive for large tables; locks the table during the operation, blocking downstream queries.
  - **Recommendation:** If the table grows >1GB, consider incremental refresh (merge/upsert) or partitioning by load date.

### Join Implications
- The code reads from a single source table (`spectrum.raw_products`) with no joins, so join performance is not a concern.
- Downstream consumers will join on `product_id` (the SORTKEY), which is optimized.

### Expensive Operations
- **CAST operations:** Type conversions are relatively cheap but add overhead. If the source system already provides correctly-typed data, consider removing unnecessary casts.
- **GETDATE():** Minimal cost; called once per row.
- **CASE statement:** Minimal cost; simple lookup.

### Scalability Considerations
- **Current design:** Suitable for product catalogs up to ~10M rows and <500GB.
- **If scaling beyond:** Consider partitioning by `category` or `launch_date`, or switching to incremental refresh with a merge strategy.

---

## Dependencies

### Upstream
| Component | Type | Criticality | Notes |
|-----------|------|-------------|-------|
| **spectrum.raw_products** | External source table | Critical | Must be available and contain the complete current product catalog. No SLA specified; recommend documenting. |
| **Redshift cluster** | Infrastructure | Critical | Requires active Redshift cluster with sufficient compute and storage. |

### Downstream
| Component | Type | Dependency | Notes |
|-----------|------|-----------|-------|
| **dim_products** | Dimensional table | Direct | Consumes `staging.stg_raw_products` to build the product dimension. Must run after this component. |
| **fct_sales** | Fact table | Indirect | Joins to `dim_products`, which depends on this staging table. |
| **fct_inventory** | Fact table | Indirect | Uses product attributes (category, supplier) for inventory analysis. |
| **rpt_product_catalog** | Reporting view | Direct | Exposes cleaned product data to BI tools and dashboards. |
| **analytics_readers** | IAM group | Direct | Granted `SELECT` permission on the output table. |

### External
| System | Purpose | Notes |
|--------|---------|-------|
| **Inventory Management System** | Source of raw product data | Provides `spectrum.raw_products` via Spectrum (external table). Refresh frequency not specified. |
| **Redshift Spectrum** | Data lake integration | Enables querying raw data in S3 without loading into Redshift. Assumes S3 bucket and Spectrum external schema are configured. |

---

## Maintenance & Operational Notes

### Monitoring & Alerting
- **Row count:** Track the number of rows loaded; sudden drops may indicate upstream data quality issues.
- **Load time:** Monitor execution duration; increases may indicate source system slowness or data volume growth.
- **NULL counts:** Monitor the number of records filtered out (where `product_id` or `product_name` is NULL); spikes indicate upstream data quality degradation.
- **Status code distribution:** Monitor the count of `'Unknown'` status values; increases may indicate new unmapped status codes in the source.

### Maintenance Tasks
1. **Update status code mapping:** If new status codes are introduced in the source system, update the `CASE` statement.
2. **Review null handling:** Periodically audit records with NULL values in optional fields to ensure they are intentional.
3. **Validate supplier_id references:** Ensure that all `supplier_id` values (except `-1`) exist in the supplier dimension.
4. **Monitor table growth:** If the table grows beyond 500GB, consider switching to incremental refresh or partitioning.

### Troubleshooting
- **Job fails with "Table does not exist":** Verify that `spectrum.raw_products` is available and accessible.
- **Job fails with "CAST error":** Check source data types; may need to add `TRY_CAST` or upstream validation.
- **Downstream queries slow:** Check that `SORTKEY(product_id)` is being used effectively; run `ANALYZE` to update table statistics.
- **Duplicate products in output:** Add deduplication logic to the SELECT statement.