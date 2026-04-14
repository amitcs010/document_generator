# config/schema_setup.sql

## Component Overview
- **Layer:** Configuration
- **Type:** Infrastructure setup script (DDL)
- **Schedule:** One-time execution during cluster initialization
- **Owner:** Data Platform / DevOps team

## Purpose
This script establishes the foundational schema architecture and access control framework for the Redshift data warehouse. It creates the logical separation of data layers (staging, transforms, marts, monitoring), defines user groups with role-based access controls, and configures permissions so that new tables automatically inherit appropriate read access. This ensures secure, scalable governance from day one and enables different teams (analytics, BI, finance) to access only the data they need without manual permission grants on every new table.

## Inputs
**No direct data inputs.** This is a configuration script that reads from:
- **data** (referenced in Dependencies) — the upstream data sources that will eventually populate these schemas, though this script doesn't directly query them

## Outputs
**No data outputs.** This script creates infrastructure:
- **Four schemas:** `staging`, `transforms`, `marts`, `monitoring`
- **Three user groups:** `analytics_readers`, `bi_team`, `finance_team`
- **One external schema:** `spectrum` (for Redshift Spectrum S3 access)
- **Permission grants:** Default privileges on all future tables in each schema

## Key Business Logic

### Schema Layering Strategy
The script implements a **medallion architecture** (bronze/silver/gold equivalent):
- **staging** — Raw ingested data, minimal transformation. Used by analytics_readers for exploration and debugging.
- **transforms** — Intermediate tables with business logic applied (joins, aggregations, calculations). Used by analytics_readers for building downstream assets.
- **marts** — Curated, production-ready tables optimized for BI and reporting. Accessible to bi_team and finance_team for dashboards and reports.
- **monitoring** — Operational metrics, data quality checks, and pipeline health. Used by analytics_readers to monitor warehouse health.

### Role-Based Access Control (RBAC)
Three distinct user groups enforce the principle of least privilege:
- **analytics_readers** — Full read access across all layers (staging → transforms → marts → monitoring). Intended for data engineers and analysts building pipelines.
- **bi_team** — Read-only access to marts only. Prevents accidental exposure to raw/intermediate data; ensures BI tools consume only validated, documented tables.
- **finance_team** — Read-only access to marts only. Restricted to finance-specific mart tables (enforced downstream via table-level grants, not shown here).

### Default Privileges Pattern
The `ALTER DEFAULT PRIVILEGES` statements ensure **automatic permission inheritance**:
- Any new table created in `staging`, `transforms`, or `marts` automatically grants SELECT to the appropriate group.
- Eliminates manual permission management and reduces risk of accidentally creating unreadable tables.
- Applies only to tables created *after* this script runs; existing tables must be granted permissions separately.

### External Schema for Spectrum
The `spectrum` schema enables querying S3 data without loading it into Redshift:
- Points to an AWS Glue Data Catalog database (`ecommerce_raw`) containing S3 object metadata.
- Uses an IAM role (`RedshiftSpectrumRole`) to authenticate S3 access.
- Allows cost-effective querying of large, infrequently accessed raw datasets.

## Column Descriptions
**N/A** — This is a DDL script that creates schemas and permissions, not tables with columns. However, the schemas created will eventually contain tables with columns as follows:

| Schema | Typical Contents | Example Tables |
|--------|------------------|-----------------|
| **staging** | Raw extracts from source systems | `stg_orders`, `stg_customers`, `stg_products` |
| **transforms** | Cleaned, deduplicated, joined intermediate tables | `fct_order_items`, `dim_customer_enhanced` |
| **marts** | Business-ready fact and dimension tables | `mart_sales_summary`, `mart_customer_lifetime_value` |
| **monitoring** | Pipeline execution logs, row counts, freshness checks | `tbl_load_audit`, `tbl_data_quality_checks` |

## Data Quality & Edge Cases

### Permission Inheritance Limitations
- **Default privileges only apply to NEW tables.** If this script is re-run on an existing cluster, previously created tables retain their old permissions. Mitigation: Run once at cluster creation, or manually GRANT permissions to existing tables.
- **Group membership changes are not retroactive.** If a user is added to `bi_team` after tables are created, they inherit default privileges only on *future* tables. Existing tables require explicit GRANT statements.

### IAM Role Assumptions
- The Redshift cluster must have the IAM role `arn:aws:iam::123456789012:role/RedshiftSpectrumRole` attached to its cluster role.
- The role must have `s3:GetObject`, `s3:ListBucket` permissions on the S3 bucket containing `ecommerce_raw` data.
- If the role is missing or misconfigured, Spectrum queries will fail with "Access Denied" errors.

### Schema Naming Conflicts
- If schemas already exist (e.g., from a previous failed setup), the `IF NOT EXISTS` clauses prevent errors but also skip re-initialization. Verify schema contents before re-running.
- Group creation will fail if groups already exist; `CREATE GROUP` has no `IF NOT EXISTS` option in Redshift (as of 2024). Manual cleanup may be required.

### External Database Assumption
- The script assumes the Glue Data Catalog database `ecommerce_raw` exists and contains valid table definitions. If it doesn't, Spectrum queries will fail with "Database not found" errors.
- The `CREATE EXTERNAL DATABASE IF NOT EXISTS` clause creates a placeholder if missing, but it will be empty until Glue crawlers or manual metadata registration populate it.

## Performance Notes

### No Performance Impact
This is a one-time setup script with negligible performance implications:
- Schema and group creation are metadata operations (no data movement).
- Permission grants are lightweight catalog updates.
- No joins, scans, or aggregations are performed.

### Spectrum Considerations
- Spectrum queries scan S3 data directly, which is slower than querying Redshift tables (network latency + S3 API calls).
- Recommended use: Querying large, cold datasets (e.g., historical archives) or data not yet loaded into Redshift.
- For frequently queried data, consider loading into Redshift tables with appropriate distribution keys for better performance.

### Distribution Key Implications
This script doesn't define distribution keys (that's done in individual table creation scripts). However:
- Tables in `staging` should typically use `DISTSTYLE KEY` on a natural join key (e.g., `order_id`) to minimize data movement during transforms.
- Tables in `marts` should use distribution keys aligned with common filter/join patterns in BI queries.

## Dependencies

### Upstream
- **AWS Account Setup** — IAM role `RedshiftSpectrumRole` must exist with S3 permissions.
- **Glue Data Catalog** — Database `ecommerce_raw` must be created and populated with table metadata (via Glue crawlers or manual registration).
- **Redshift Cluster** — Cluster must be provisioned and accessible.

### Downstream
- **All data pipeline scripts** — Every ETL/ELT script that creates tables in `staging`, `transforms`, or `marts` depends on this schema setup. Tables cannot be created in non-existent schemas.
- **User onboarding** — New users must be added to one of the three groups (`analytics_readers`, `bi_team`, `finance_team`) to access data.
- **BI tools** (Tableau, Looker, etc.) — Must connect using credentials for users in `bi_team` or `finance_team` to access mart tables.
- **Monitoring dashboards** — Depend on the `monitoring` schema existing for health check tables.

### External
- **AWS IAM** — Role `arn:aws:iam::123456789012:role/RedshiftSpectrumRole` must be created and attached to the Redshift cluster.
- **AWS Glue Data Catalog** — Database `ecommerce_raw` must exist (created separately, not by this script).
- **S3 bucket** — Must contain raw data files referenced by Glue table definitions.

### Related Configuration Files
- `config/table_definitions.sql` — Creates individual tables within these schemas.
- `config/iam_setup.tf` — Terraform code that creates the IAM role referenced in the Spectrum schema.
- `config/glue_crawler_config.json` — Glue crawler configuration that populates the `ecommerce_raw` database.

## Execution Checklist
- [ ] Verify AWS account ID in IAM role ARN matches your account (currently hardcoded as `123456789012`).
- [ ] Confirm `RedshiftSpectrumRole` exists and has S3 permissions.
- [ ] Confirm Glue database `ecommerce_raw` exists.
- [ ] Run this script once during cluster initialization (not on every deployment).
- [ ] After execution, verify schemas exist: `SELECT * FROM information_schema.schemata;`
- [ ] Verify groups exist: `SELECT * FROM pg_group;`
- [ ] Document which users belong to which groups in your access control matrix.