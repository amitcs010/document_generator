# Documentation: staging.stg_raw_orders

**Purpose**
Staging layer that ingests raw order data from S3 parquet files via Spectrum, standardizes column types and naming conventions, filters out test orders and system cancellations, and loads cleaned data into Redshift for downstream analytics consumption.

**Inputs**
- `spectrum.raw_orders` (S3-backed external table)

**Outputs**
- `staging.stg_raw_orders` (Redshift table, distributed on order_id, sorted on order_date)

**Key Transformations**
- Type casting: IDs to BIGINT, amounts to DECIMAL(12,2), codes/methods to VARCHAR
- Date/timestamp conversions from raw created_at/updated_at fields
- Null handling: coupon_code defaults to 'NONE', channel defaults to 'web'
- Filtering: excludes test orders (is_test=FALSE), system cancellations, zero/negative amounts, and data older than 3 days
- Metadata: adds _loaded_at timestamp for lineage tracking

**Dependencies**
- Schedule: Daily at 02:00 UTC
- Owner: Data Engineering
- Downstream consumers: analytics_readers group (SELECT grant applied)

**Notes**
- Table is recreated daily (DROP/CREATE pattern); uses rolling 3-day window to optimize for incremental patterns
- DISTKEY/SORTKEY optimize for order_id joins and order_date range queries
- ANALYZE command updates table statistics post-load