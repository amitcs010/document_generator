# config/schema_setup.sql

## Component Overview
- **Layer:** Configuration
- **Type:** Infrastructure setup script (DDL)
- **Schedule:** One-time execution during cluster initialization; re-runnable for idempotent updates
- **Owner:** Data Platform / DevOps (typically run during cluster provisioning)

## Purpose
This script establishes the foundational schema architecture, access control framework, and external data connectivity for the Redshift warehouse. It creates the logical separation of concerns (staging → transforms → marts) and implements role-based access control (RBAC) to ensure data governance, security, and appropriate access patterns across analytics, BI, and finance teams. Without this setup, the warehouse cannot enforce data lineage, permission boundaries, or external data integration.

## Inputs
**No direct data inputs.** This is a configuration script that:
- Assumes AWS IAM role `arn:aws:iam::123456789012:role/RedshiftSpectrumRole` exists and has S3 permissions
- Assumes AWS Glue Catalog database `ecommerce_raw` exists (for Spectrum external schema)
- Assumes Redshift cluster is initialized and user has superuser/admin privileges

## Outputs
**No data outputs.** This script creates infrastructure:
- **4 schemas:** `staging`, `transforms`, `marts`, `monitoring`
- **3 user groups:** `analytics_readers`, `bi_team`, `finance_team`
- **1 external schema:** `spectrum` (pointing to S3 via Redshift Spectrum)
- **Default privilege grants** applied to all future tables in each schema

## Key Business Logic

### Schema Layering Strategy
The script implements a **medallion architecture** (bronze/silver/gold equivalent):

1. **staging** — Raw ingested data from source systems (ERP, payment processors, web logs). Minimal transformation. Typically loaded via ETL tools (Fivetran, custom Lambda, etc.). Read-only access for analytics team to audit data quality.

2. **transforms** — Intermediate cleaned, deduplicated, and conformed data. Business logic applied (e.g., customer deduplication, order status standardization). Acts as a "working layer" for data engineers. Not exposed to end users.

3. **marts** — Curated, business-ready dimensional and fact tables (e.g., `dim_customer`, `fact_orders`). Optimized for BI tool queries and reporting. Exposed to BI team and finance team with appropriate row-level or column-level filtering (not enforced here, but assumed in downstream BI tools).

4. **monitoring** — Data quality metrics, pipeline run logs, and SLA tracking. Used by data engineers and platform teams to detect failures and data anomalies.

### Access Control Strategy
The script implements **principle of least privilege** via group-based RBAC:

- **analytics_readers** — Full read access to staging, transforms, marts, and monitoring. Intended for data engineers and analytics engineers who need to debug and audit the full pipeline.
- **bi_team** — Read-only access to marts only. Prevents accidental exposure to raw/intermediate data and enforces consumption of curated tables.
- **finance_team** — Read-only access to marts only. Ensures finance uses validated, audited data for reporting and compliance.

### Default Privileges Pattern
The `ALTER DEFAULT PRIVILEGES` statements ensure that **any new table created in a schema automatically inherits the appropriate group permissions**. This prevents the common mistake of creating a new table and forgetting to grant access, which would break downstream pipelines or BI dashboards.

### External Schema (Spectrum) Integration
The `spectrum` external schema enables querying S3 data directly without loading into Redshift. This is cost-effective for:
- Large historical archives (e.g., 5+ years of transaction logs)
- Infrequently accessed raw data
- Data that must remain in S3 for compliance/audit trails

The IAM role grants Redshift permission to read from S3 without embedding credentials in the cluster.

## Column Descriptions
**N/A — This is a DDL script, not a data transformation.** It creates schemas and permissions, not tables with columns.

However, the **downstream marts** created by this schema will typically contain columns like:
- **customer_id** — PK, uniquely identifies a customer
- **order_id** — PK/FK, uniquely identifies an order
- **order_date** — TIMESTAMP, when the order was placed
- **total_amount** — DECIMAL(10,2), order revenue in USD
- **status** — VARCHAR, order state (pending, shipped, delivered, cancelled)

These are defined in separate transformation scripts, not here.

## Data Quality & Edge Cases

### Idempotency
All `CREATE` statements use `IF NOT EXISTS` to allow safe re-runs. This is critical for:
- Infrastructure-as-code (IaC) deployments that may run this script multiple times
- Cluster recovery scenarios
- Development/test environment setup

**Edge case:** If a schema already exists but with different permissions, this script will **not** modify existing permissions. Manual cleanup may be required.

### Permission Inheritance Gaps
**Assumption:** Default privileges only apply to tables created **after** this script runs. Existing tables in these schemas will not automatically inherit permissions. Mitigation: Run explicit `GRANT` statements for pre-existing tables.

**Edge case:** If a user creates a table directly in a schema (not via a role), the table owner may have different permissions than expected. Enforce table creation via stored procedures or dbt models to ensure consistency.

### IAM Role Validity
**Assumption:** The IAM role `arn:aws:iam::123456789012:role/RedshiftSpectrumRole` exists and has:
- `s3:GetObject` on the S3 bucket containing `ecommerce_raw`
- `glue:GetDatabase`, `glue:GetTable`, `glue:GetPartitions` on the Glue Catalog

**Edge case:** If the role is deleted or permissions are revoked, Spectrum queries will fail silently with "table not found" errors. Monitor CloudTrail for IAM permission denials.

### Glue Catalog Database Assumption
**Assumption:** AWS Glue Catalog database `ecommerce_raw` exists and contains table definitions for S3 data.

**Edge case:** If the database doesn't exist, the `CREATE EXTERNAL SCHEMA` will fail. The `CREATE EXTERNAL DATABASE IF NOT EXISTS` clause will auto-create it, but it will be empty. Ensure Glue Crawler or manual table registration populates it.

### Group Membership Not Defined
**Limitation:** This script creates groups but does **not** assign users to groups. A separate step (via AWS console, CLI, or Terraform) must add users to `analytics_readers`, `bi_team`, and `finance_team`. If no users are added, the groups are inert.

## Performance Notes

### Schema Distribution
Redshift distributes tables across compute nodes based on a **distribution key** (not specified here, but critical downstream). This script does not define distribution keys; they are set when tables are created in each schema.

**Implication:** Poorly chosen distribution keys can cause data skew and slow joins. Recommend:
- `staging` tables: distribute on natural PK (e.g., `source_id`) to match source system partitioning
- `transforms` tables: distribute on common join keys (e.g., `customer_id`)
- `marts` tables: distribute on fact table FKs (e.g., `customer_id` for `fact_orders`)

### Spectrum Performance
Querying `spectrum` external tables is **slower than native Redshift tables** because data must be read from S3 over the network. Typical latency: 2-10x slower than local tables.

**Optimization:** Use Spectrum for:
- Infrequent queries (e.g., annual compliance audits)
- Large scans where network I/O is acceptable
- Data that doesn't fit in Redshift (cost-prohibitive)

**Anti-pattern:** Do NOT use Spectrum for real-time dashboards or sub-second queries.

### Permission Checks Overhead
Every query execution checks group membership and table permissions. This is negligible for most workloads but can add latency for:
- Thousands of small queries (e.g., rapid-fire BI dashboard refreshes)
- Complex permission hierarchies (not present here, but possible in future)

**Mitigation:** Use materialized views in `marts` to pre-compute expensive queries and reduce permission checks.

## Dependencies

### Upstream
- **AWS Account & IAM:** Must have permissions to create IAM roles and Glue Catalog databases
- **Redshift Cluster:** Must be initialized and accessible
- **AWS Glue Catalog:** Must exist (auto-created with AWS account)
- **S3 Bucket:** Must exist and contain raw data for Spectrum queries
- **IAM Role `RedshiftSpectrumRole`:** Must be created separately (typically via Terraform or CloudFormation)

**Typical execution order:**
1. Provision AWS account and IAM roles (Terraform/CloudFormation)
2. Create Redshift cluster
3. Create S3 bucket and upload raw data
4. Register S3 data in Glue Catalog (via Crawler or manual DDL)
5. **Run this script** (`schema_setup.sql`)
6. Run data ingestion pipelines (Fivetran, Lambda, dbt)

### Downstream
- **All ETL/ELT pipelines:** Depend on `staging` schema existing to load raw data
- **dbt models:** Depend on `transforms` and `marts` schemas for model materialization
- **BI tools (Tableau, Looker, etc.):** Depend on `marts` schema and group permissions being configured
- **Data quality monitoring:** Depends on `monitoring` schema for logging
- **Spectrum queries:** Depend on external schema and Glue Catalog registration

**Critical path:**
```
schema_setup.sql
    ↓
[Data ingestion to staging]
    ↓
[dbt transforms → transforms schema]
    ↓
[dbt marts → marts schema]
    ↓
[BI tools query marts]
```

### External Systems & Configs
- **AWS IAM:** Role `arn:aws:iam::123456789012:role/RedshiftSpectrumRole` must exist
- **AWS Glue Catalog:** Database `ecommerce_raw` must be registered
- **S3:** Bucket containing raw data (path not specified in this script; assumed in Glue Catalog)
- **Redshift Parameter Groups:** May need to adjust `max_query_queue_time`, `statement_timeout` for large Spectrum queries
- **Network:** Redshift cluster must have VPC endpoint or NAT gateway to reach S3 (for Spectrum)

### Maintenance & Monitoring
- **Quarterly review:** Audit group membership and permissions for role changes
- **Annual review:** Validate that all schemas are in use; archive unused schemas
- **Monitor:** CloudWatch metrics for Spectrum query latency; alert if >10s average
- **Backup:** This script should be version-controlled in Git; cluster snapshots should be automated

---

## Deployment Checklist
- [ ] IAM role `RedshiftSpectrumRole` created with S3 and Glue permissions
- [ ] Glue Catalog database `ecommerce_raw` exists
- [ ] S3 bucket created and raw data uploaded
- [ ] Redshift cluster provisioned and accessible
- [ ] Run `schema_setup.sql` as superuser
- [ ] Verify schemas created: `SELECT * FROM information_schema.schemata;`
- [ ] Verify groups created: `SELECT * FROM pg_group;`
- [ ] Assign users to groups via `ALTER GROUP ... ADD USER ...`
- [ ] Test Spectrum query: `SELECT COUNT(*) FROM spectrum.<table_name>;`
- [ ] Document AWS account ID and IAM role ARN in runbook