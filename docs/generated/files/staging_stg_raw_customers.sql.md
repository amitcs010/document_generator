# Documentation: staging.stg_raw_customers

**Purpose**
Ingests and cleanses customer records from the CRM export (S3 CSV via Spectrum), deduplicates by customer_id (retaining the most recent record), and applies PII masking to sensitive fields for safe downstream analytics consumption.

**Inputs**
- `spectrum.raw_customers` – Raw customer data from S3 CSV export

**Outputs**
- `staging.stg_raw_customers` – Deduplicated, masked customer staging table
- Permissions: SELECT granted to `analytics_readers` group

**Key Transformations**
- **Deduplication**: ROW_NUMBER() partitioned by customer_id, ordered by updated_at DESC; retains row 1 only
- **PII Masking**: Email hashed (MD5), names truncated (first letter + ***), phone reduced to country prefix, postal code truncated
- **Data Extraction**: Email domain preserved for analytics; country code retained
- **Validation**: Filters null customer_id and invalid emails (length ≤ 3)
- **Enrichment**: Calculates days_since_registration; applies default values (loyalty_tier='Bronze', LTV=0)
- **Type Casting**: Explicit CAST/CONVERT for consistency (BIGINT, VARCHAR, DATE, DECIMAL)

**Dependencies**
- Upstream: `spectrum.raw_customers` (Redshift Spectrum external table)
- Downstream: Analytics queries via `analytics_readers` group

**Notes**
- Distributed and sorted by customer_id for query optimization
- Table recreated on each run (DROP TABLE IF EXISTS)
- ANALYZE executed post-load for query planner statistics
- Load timestamp (`_loaded_at`) captured for audit trail