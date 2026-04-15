# config/schema_setup.sql

## Component Overview
- **Layer:** Configuration
- **Type:** Infrastructure setup script (DDL)
- **Schedule:** One-time execution during cluster initialization; re-runnable for idempotent updates
- **Owner:** Data Platform / DevOps (typically run during cluster provisioning)

## Purpose

This script establishes the foundational schema architecture, access control framework, and external data connectivity for the Redshift warehouse. It creates the logical separation of concerns (staging → transforms → marts) that enables the data pipeline to operate with clear boundaries between raw ingestion, transformation logic, and business-ready analytics. By defining role-based access controls at the schema level with default privileges, it ensures that new tables automatically inherit appropriate permissions, reducing manual access management overhead and enforcing consistent security posture across the warehouse.

## Inputs

**No direct data inputs.** This is a configuration script that operates on the Redshift cluster metadata layer. It assumes:
- A Redshift cluster is provisioned and accessible
- An IAM role (`RedshiftSpectrumRole`) exists in AWS account `123456789012` with permissions to read from S3 bucket `ecommerce_raw`
- Glue Catalog database `ecommerce_raw` is configured and contains external table metadata

## Outputs

**No data tables produced.** This script creates infrastructure:

| Artifact | Type | Purpose |
|----------|------|---------|
| `staging` schema | Schema container | Holds raw/ingested tables from source systems (ERP, payment processors, etc.) |
| `transforms` schema | Schema container | Holds intermediate transformation tables and CTEs materialized for reuse |
| `marts` schema | Schema container | Holds business-ready dimensional and fact tables consumed by BI tools and reporting |
| `monitoring` schema | Schema container | Holds operational metadata, data quality checks, and pipeline logs |
| `spectrum` external schema | External schema | Provides query-able access to Parquet/CSV files in S3 without loading into Redshift |
| `analytics_readers` group | IAM group | Read-only access to staging, transforms, marts, and monitoring schemas |
| `bi_team` group | IAM group | Read-only access to marts schema (curated analytics layer) |
| `finance_team` group | IAM group | Read-only access to marts schema (finance-specific fact tables) |

## Key Business Logic

### Schema Layering Strategy
The four-schema architecture enforces a **medallion/lakehouse pattern**:

1. **staging** — Raw data as-ingested from source systems. Minimal transformation. Enables audit trails and debugging of data quality issues at source.
2. **transforms** — Intermediate tables used during ETL. Includes slowly-changing dimensions, deduplication logic, and cross-system joins. Not exposed to end users; used only by data engineers.
3. **marts** — Curated, business-ready tables. Fact tables (events, transactions) and dimensions (customers, products, dates). Optimized for BI query patterns. This is the "single source of truth" for analytics.
4. **monitoring** — Operational metadata: row counts, freshness timestamps, data quality test results, pipeline execution logs. Enables alerting and SLA tracking.

### Role-Based Access Control (RBAC)
Three user groups enforce principle of least privilege:

- **analytics_readers** — Data engineers and analysts. Full read access to all layers (staging through monitoring). Can debug issues end-to-end.
- **bi_team** — Business analysts and dashboard developers. Read-only access to `marts` only. Prevents accidental queries on raw/intermediate data; ensures they use curated definitions.
- **finance_team** — Finance stakeholders and controllers. Read-only access to `marts` only. Scoped to finance-specific fact tables via downstream table-level grants (not shown in this script).

### Default Privileges Pattern
The `ALTER DEFAULT PRIVILEGES` statements ensure **automatic permission inheritance**:
- When a new table is created in `staging`, all members of `analytics_readers` automatically gain SELECT
- When a new table is created in `marts`, both `bi_team` and `finance_team` automatically gain SELECT
- This eliminates the need for manual GRANT statements after each ETL load, reducing operational toil and permission drift

### External Schema (Spectrum) Integration
The `spectrum` schema bridges Redshift and S3:
- Enables querying of raw files (Parquet, CSV, ORC) stored in S3 without copying into Redshift
- Reduces storage costs for cold/archive data
- Allows data scientists to query raw logs and events without loading into the warehouse
- Uses Glue Catalog as metadata layer (schema inference, partition discovery)

## Column Descriptions

**N/A** — This script does not produce data columns. It creates schema containers and access control structures. Refer to downstream table documentation (e.g., `marts.fct_orders`, `marts.dim_customers`) for column specifications.

## Data Quality & Edge Cases

### Idempotency
- All CREATE statements use `IF NOT EXISTS` clauses, allowing safe re-execution without errors
- Useful for infrastructure-as-code (Terraform, CloudFormation) workflows where scripts may run multiple times
- **Edge case:** If a schema already exists but with different permissions, this script will not modify existing permissions. Manual cleanup required.

### Permission Assumptions
- Script assumes IAM role `RedshiftSpectrumRole` exists and is trusted by the Redshift cluster
- If role ARN is incorrect or role lacks S3 permissions, Spectrum queries will fail silently at runtime
- **Mitigation:** Test Spectrum connectivity immediately after setup: `SELECT * FROM spectrum.raw_events LIMIT 1;`

### Group Membership Not Defined
- Script creates groups but does **not** assign users to groups
- Separate process required to add users: `ALTER GROUP analytics_readers ADD USER alice;`
- **Risk:** Groups remain empty until manually populated; users will lack access despite group grants

### Schema Naming Conventions
- Assumes downstream processes follow naming convention: `staging.raw_*`, `transforms.int_*`, `marts.fct_*` / `marts.dim_*`
- If naming conventions are violated, documentation and tooling (data catalogs, lineage tools) may fail to auto-categorize tables

### AWS Account Hardcoding
- IAM role ARN contains hardcoded account ID `123456789012`
- **Must be updated** for each environment (dev, staging, prod)
- **Mitigation:** Use environment variables or Terraform variables to inject correct account ID

## Performance Notes

### Schema Design Implications
- **No distribution keys or sort keys defined** — This script only creates schemas; distribution/sort keys are defined per-table in downstream DDL
- **Spectrum queries** — External schema queries are slower than native Redshift tables (network latency to S3). Recommended for ad-hoc analysis, not real-time dashboards. Consider materializing frequently-queried Spectrum tables into `staging` or `transforms`

### Permission Lookup Overhead
- Default privileges are checked at table creation time, not query time
- No runtime performance impact from RBAC; permissions are resolved during query planning
- Large numbers of groups (>50) can slow down permission resolution; current design (3 groups) is optimal

### Spectrum Metadata Caching
- Glue Catalog metadata is cached by Redshift; changes to S3 partitions may not be immediately visible
- Workaround: `MSCK REPAIR TABLE spectrum.table_name;` to refresh partition metadata (requires Spectrum role permissions)

## Dependencies

### Upstream
- **AWS Infrastructure:** Redshift cluster must be provisioned and running
- **IAM Setup:** Role `arn:aws:iam::123456789012:role/RedshiftSpectrumRole` must exist with inline policy:
  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": ["s3:GetObject", "s3:ListBucket"],
        "Resource": ["arn:aws:s3:::ecommerce_raw/*", "arn:aws:s3:::ecommerce_raw"]
      },
      {
        "Effect": "Allow",
        "Action": ["glue:GetDatabase", "glue:GetTable", "glue:GetPartitions"],
        "Resource": "*"
      }
    ]
  }
  ```
- **Glue Catalog:** Database `ecommerce_raw` must exist with external table definitions

### Downstream
- **All ETL pipelines** — Depend on these schemas existing before data can be loaded
  - `staging` schema required by: data ingestion jobs (Fivetran, custom Python/Spark loaders)
  - `transforms` schema required by: dbt, Airflow DAGs, stored procedures
  - `marts` schema required by: BI tools (Tableau, Looker), reporting dashboards, analytics queries
  - `monitoring` schema required by: data quality frameworks (Great Expectations, dbt tests), alerting systems
- **User onboarding** — New analysts/engineers cannot access warehouse until added to appropriate groups
- **Access control policies** — Downstream table-level grants (e.g., `GRANT SELECT ON marts.fct_orders TO GROUP finance_team;`) build on top of schema-level permissions

### External
- **AWS Glue Catalog** — Metadata source for Spectrum external tables
- **S3 bucket `ecommerce_raw`** — Data source for Spectrum queries
- **IAM service** — Manages role trust relationships and permission evaluation
- **Redshift cluster parameter group** — Must have `enable_user_activity_logging` enabled if audit logging is required

### Related Configuration Files
- `dbt/profiles.yml` — Must reference schema names defined here (staging, transforms, marts)
- `airflow/dags/etl_pipeline.py` — Assumes these schemas exist before task execution
- `monitoring/data_quality_checks.sql` — Queries `monitoring` schema for test results
- `.env` / `terraform/variables.tf` — Should parameterize AWS account ID and IAM role ARN

## Maintenance & Troubleshooting

### Common Issues

| Issue | Cause | Resolution |
|-------|-------|-----------|
| `ERROR: schema "staging" already exists` | Script run twice without `IF NOT EXISTS` | Use current script version (includes IF NOT EXISTS) |
| `ERROR: permission denied for schema staging` | User not in any group with schema USAGE | `ALTER GROUP analytics_readers ADD USER username;` |
| `ERROR: external schema spectrum does not exist` | IAM role ARN incorrect or role lacks S3 permissions | Verify role ARN and S3 bucket policy; test with `SELECT * FROM spectrum.table LIMIT 1;` |
| New tables in `marts` not readable by `bi_team` | Default privileges not applied (table created before script ran) | Manually grant: `GRANT SELECT ON marts.new_table TO GROUP bi_team;` |

### Monitoring
- Query `pg_user_info` to verify group membership: `SELECT * FROM pg_user_info WHERE usegroup = 'analytics_readers';`
- Query `pg_default_acl` to verify default privileges: `SELECT * FROM pg_default_acl WHERE defaclschema = (SELECT oid FROM pg_namespace WHERE nspname = 'marts');`