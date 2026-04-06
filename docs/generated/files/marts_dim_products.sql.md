# marts.dim_products Documentation

**Purpose**
Creates a comprehensive product dimension table enriched with historical sales performance metrics, inventory status, and product tiering. Serves as the authoritative product reference for analytics and BI reporting, combining master product attributes with aggregated order-level metrics.

**Inputs**
- `staging.stg_raw_products` – Master product catalog with attributes (SKU, category, pricing, inventory)
- `transforms.int_order_items` – Order line items with sales transactions and metrics

**Outputs**
- `marts.dim_products` – Denormalized product dimension (Redshift, DISTSTYLE ALL, SORTKEY on product_id)

**Key Transformations**
- Aggregates order items by product (units sold, revenue, margin, customer/order counts)
- Excludes cancelled and fraud_review orders from sales metrics
- Calculates list margin percentage and average selling price with null handling
- Derives inventory status classification (Out of Stock/Low/Normal/Well Stocked)
- Computes days since last sale and revenue-based quartile ranking (NTILE)
- Left joins to preserve products with no sales history

**Dependencies**
- Upstream: `staging.stg_raw_products`, `transforms.int_order_items`
- Downstream: Analytics and BI tools (analytics_readers, bi_team groups)

**Notes**
- Table is dropped and recreated (full refresh pattern)
- Includes audit column `_loaded_at` for lineage tracking
- ANALYZE command optimizes query planning post-load
- NVL defaults handle products with zero sales activity