# config/schema_setup.sql

## Component Overview
- **Layer:** Configuration
- **Type:** Infrastructure setup script (DDL)
- **Schedule:** One-time execution during cluster initialization
- **Owner:** Data Platform / DevOps team

## Purpose
This script establishes the foundational schema architecture and access control framework for the Redshift data warehouse. It creates the logical container schemas (staging, transforms, marts, monitoring), defines user groups with role-based access patterns, and configures default privileges to ensure new tables inherit appropriate permissions automatically. This is a prerequisite for all downstream data pipelines and ensures consistent, secure access governance across the organization without requiring manual permission grants for each new table.

## Inputs
**No direct data inputs.** This is an infrastructure setup script that reads from:
- **AWS IAM roles** — specifically `RedshiftSpectrumRole` for S3 access via Spectrum
- **AWS Glue Data Catalog** — the `ecommerce_raw` database for external schema mapping

## Outputs
**No data outputs.** This script creates infrastructure:
- **Four schemas:** `staging`, `transforms`, `marts`, `monitoring`
- **Three user groups:** `analytics_readers`, `bi_team`, `finance_team`
- **One external schema:** `spectrum` (mapped to S3 via Glue Catalog)
- **Default privilege rules:** Automatic SELECT grants on all future tables in each schema

## Key Business Logic

### Schema Layering Strategy
The script implements a **medallion architecture** with four distinct layers:

1. **staging** — Raw data ingestion zone
   - Receives unprocessed data from source systems
   - Temporary landing area; data is typically ephemeral
   - Used by analytics_readers for debugging and validation

2. **transforms** — Intermediate transformation zone
   - Contains cleaned, deduplicated, and normalized intermediate tables
   - Bridges raw staging data to business-ready marts
   - Isolated from direct BI tool access to prevent dependency on unstable intermediate logic

3. **marts** — Business-ready analytics zone
   - Contains final, curated tables optimized for BI tools and reporting
   - Consumed by bi_team (dashboards), finance_team (reporting), and analytics_readers (ad-hoc analysis)
   - Represents the "single source of truth" for business metrics

4. **monitoring** — Observability and data quality zone
   - Tracks pipeline execution, data freshness, and quality metrics
   - Consumed by analytics_readers for SLA monitoring and troubleshooting

### Role-Based Access Control (RBAC)
Three user groups enforce separation of concerns:

| Group | Schemas | Purpose | Typical Users |
|-------|---------|---------|---|
| `analytics_readers` | staging, transforms, marts, monitoring | Ad-hoc analysis, debugging, data exploration | Data analysts, data scientists |
| `bi_team` | marts only | Dashboard and report creation | BI developers, report authors |
| `finance_team` | marts only | Financial reporting and compliance | Finance analysts, controllers |

**Rationale:** 
- `bi_team` and `finance_team` have restricted access to marts only, preventing accidental dependencies on unstable intermediate tables
- `analytics_readers` has broader access for troubleshooting and exploratory work
- No group has write access (only SELECT granted), enforcing data governance through the pipeline

### Default Privileges Pattern
```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA [schema] GRANT SELECT ON TABLES TO GROUP [group]
```
This ensures that **any new table created in a schema automatically inherits the appropriate permissions** without manual intervention. This prevents:
- Accidental permission gaps when new tables are added
- Manual permission management overhead
- Inconsistent access patterns across tables

### External Schema (Spectrum) Configuration
The `spectrum` schema provides query-in-place access to S3 data via Redshift Spectrum:
- **Source:** AWS Glue Data Catalog database `ecommerce_raw`
- **IAM Role:** `RedshiftSpectrumRole` grants Redshift permission to read S3 objects
- **Use case:** Query raw data files (Parquet, CSV, ORC) without loading into Redshift, reducing storage costs for historical/archive data

## Column Descriptions
**N/A** — This is a DDL script that creates schemas and permissions, not a data table. However, the schemas it creates will contain the following types of columns:

| Schema | Typical Column Types | Examples |
|--------|---------------------|----------|
| **staging** | Raw source columns | `customer_id`, `order_date`, `raw_json_payload` |
| **transforms** | Cleaned/normalized columns | `customer_key`, `order_date_key`, `total_amount_usd` |
| **marts** | Business-ready columns | `customer_id`, `order_month`, `revenue`, `product_category` |
| **monitoring** | Metadata columns | `table_name`, `row_count`, `last_updated_at`, `data_quality_score` |

## Data Quality & Edge Cases

### Assumptions
1. **AWS IAM role exists:** The script assumes `arn:aws:iam::123456789012:role/RedshiftSpectrumRole` is already created and has S3 read permissions
2. **Glue Catalog is populated:** The `ecommerce_raw` database must exist in AWS Glue before Spectrum queries will work
3. **Idempotency:** All `CREATE ... IF NOT EXISTS` statements allow safe re-runs without errors
4. **Single-run execution:** This script is designed to run once; re-running is safe but unnecessary

### Potential Failure Points
| Issue | Impact | Mitigation |
|-------|--------|-----------|
| IAM role ARN is incorrect or role doesn't exist | Spectrum schema creation fails silently; queries will fail at runtime | Validate IAM role exists and has S3 permissions before running |
| Glue Catalog database doesn't exist | Spectrum schema creation succeeds but queries fail | Ensure `ecommerce_raw` database is created in Glue Catalog first |
| User runs script without superuser privileges | All CREATE statements fail | Ensure script is run by a Redshift superuser or role with DDL permissions |
| AWS account ID is hardcoded incorrectly | Spectrum role ARN is invalid | Update the account ID (123456789012) to match your AWS account |

### Permission Inheritance Behavior
- **New tables created after this script:** Automatically inherit SELECT grants for their schema's groups
- **Existing tables before this script:** Do NOT automatically inherit permissions; must be granted manually
- **Tables created by non-superusers:** Inherit default privileges only if the creator has the appropriate schema permissions

## Performance Notes

### Schema Distribution & Design
- **No explicit distribution keys defined** — Redshift will use default distribution (hash on first column or round-robin)
- **Recommendation:** Define distribution keys on large fact tables in `marts` schema during table creation to optimize join performance
  - Example: `DISTKEY(customer_id)` for customer-centric fact tables
  - Example: `DISTKEY(order_id)` for order-centric fact tables

### External Schema (Spectrum) Performance Considerations
- **Spectrum queries are slower** than native Redshift tables (network latency to S3)
- **Best practice:** Use Spectrum for infrequent queries on large historical datasets; move frequently-queried data into native Redshift tables
- **Partition pruning:** Ensure S3 data is partitioned by date/region to minimize data scanned

### No Expensive Operations
This is a DDL script with no data movement; performance impact is negligible (milliseconds to execute).

## Dependencies

### Upstream
- **AWS Infrastructure:**
  - Redshift cluster must be provisioned and running
  - IAM role `RedshiftSpectrumRole` must exist with S3 read permissions
  - AWS Glue Catalog database `ecommerce_raw` must be created
  - S3 bucket containing raw data must be accessible to the IAM role

- **Manual Prerequisites:**
  - Redshift superuser credentials to execute DDL
  - AWS account ID (currently hardcoded as `123456789012` — must be updated)

### Downstream
**All data pipelines depend on this script:**
- `pipelines/ingest_*.sql` — Load data into `staging` schema
- `transforms/dbt_models/` — Transform data in `transforms` schema
- `marts/fact_*.sql`, `marts/dim_*.sql` — Create business-ready tables in `marts` schema
- `monitoring/data_quality_checks.sql` — Monitor data in `monitoring` schema
- BI tools (Tableau, Looker, etc.) — Query tables in `marts` schema via `bi_team` group
- Finance reporting systems — Query tables in `marts` schema via `finance_team` group

### External Systems
- **AWS IAM** — Manages role-based access to S3 and Redshift
- **AWS Glue Data Catalog** — Provides metadata for Spectrum external schema
- **S3** — Stores raw data files accessed via Spectrum
- **Redshift cluster** — Executes all DDL and DML statements

## Maintenance & Operational Notes

### When to Re-run
- **Do NOT re-run in production** after initial setup (safe but unnecessary)
- **Re-run in new environments** (dev, staging, prod) during cluster provisioning
- **Modify and re-run** only if adding new schemas, groups, or changing permission models

### Common Modifications
```sql
-- Add a new user group
CREATE GROUP data_scientists;
ALTER DEFAULT PRIVILEGES IN SCHEMA transforms GRANT SELECT ON TABLES TO GROUP data_scientists;

-- Add a new schema
CREATE SCHEMA IF NOT EXISTS archive;
GRANT USAGE ON SCHEMA archive TO GROUP analytics_readers;

-- Grant write access to a specific group (for data engineers)
CREATE GROUP data_engineers;
GRANT USAGE ON SCHEMA staging TO GROUP data_engineers;
GRANT CREATE ON SCHEMA staging TO GROUP data_engineers;
```

### Monitoring & Validation
After running this script, validate with:
```sql
-- Check schemas exist
SELECT * FROM information_schema.schemata WHERE schema_name IN ('staging', 'transforms', 'marts', 'monitoring');

-- Check groups exist
SELECT * FROM pg_group WHERE groname IN ('analytics_readers', 'bi_team', 'finance_team');

-- Check default privileges
SELECT * FROM information_schema.role_table_grants WHERE grantee IN ('analytics_readers', 'bi_team', 'finance_team');
```