# stg_raw_products.sql Documentation

**Purpose**
Performs a full refresh of the product catalog from the inventory system into a staging layer. Implements SCD Type 1 logic by completely overwriting existing data with the latest product information, including standardized data types, status mappings, and metadata enrichment.

**Inputs**
- `spectrum.raw_products` – Raw product data from inventory system

**Outputs**
- `staging.stg_raw_products` – Cleaned and transformed product dimension table

**Key Transformations**
- Type casting: IDs to BIGINT, strings to VARCHAR, decimals to DECIMAL with appropriate precision
- Status mapping: Single-character codes (A/D/O) converted to human-readable labels (Active/Discontinued/Out of Stock)
- Null handling: Missing supplier_id replaced with -1; rows with null product_id or name filtered out
- Date conversion: Launch and restock dates standardized to DATE format
- Metadata: Load timestamp (`_loaded_at`) added via GETDATE()

**Dependencies**
- Source: `spectrum.raw_products` (Redshift Spectrum external table)
- Downstream: `analytics_readers` group has SELECT permissions

**Notes**
- Uses atomic table swap (DROP → CREATE → RENAME) within transaction for zero-downtime updates
- DISTSTYLE ALL and SORTKEY(product_id) optimize for analytical queries
- ANALYZE command updates table statistics post-load
- Full refresh approach; no incremental logic or historical tracking