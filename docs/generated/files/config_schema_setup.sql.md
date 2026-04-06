# config/schema_setup.sql

## Component Overview
- **Layer:** Configuration
- **Type:** Infrastructure setup script (DDL)
- **Schedule:** One-time execution during cluster initialization
- **Owner:** Data Platform / Infrastructure team

## Purpose

This script establishes the foundational schema architecture and access control framework for the Redshift-based e-commerce data warehouse. It creates the logical separation of concerns across the data pipeline (staging → transforms → marts), defines user groups with role-based access control (RBAC), and configures permissions to ensure data governance while enabling self-service analytics. This is a prerequisite for all downstream data pipelines and must be executed exactly once when provisioning a new Redshift cluster.

## Inputs

**No direct data inputs.** This is a configuration script that operates on the Redshift cluster infrastructure itself. It does reference:
- **IAM role** (`RedshiftSpectrumRole`) — AWS identity used to grant Redshift permission to read from S3 via Spectrum
- **S3 external database** (`ecommerce_raw`) — Glue Catalog database containing raw data definitions for Spectrum queries

## Outputs

This script does not produce data tables or views. Instead, it creates:

| Output | Type | Purpose |
|--------|------|---------|
| **staging** | Schema | Landing zone for raw data ingestion; temporary tables and initial loads |
| **transforms** | Schema | Intermediate transformation layer; cleaned, deduplicated, and enriched datasets |
| **marts** | Schema | Business-ready dimensional and fact tables; consumed by BI tools and reporting |
| **monitoring** | Schema | Operational metadata; pipeline logs, data quality metrics, and SLA tracking |
| **spectrum** | External Schema | Virtual schema mapping to S3 data via Redshift Spectrum; enables querying raw files without loading |
| **analytics_readers** | User Group | Read-only access to staging, transforms, marts, and monitoring schemas |
| **bi_team** | User Group | Read-only access to marts schema for dashboard and report creation |
| **finance_team** | User Group | Read-only access to marts schema for financial reporting and analysis |

## Key Business Logic

### 1. **Schema Layering Strategy**
The script implements a medallion architecture (bronze/silver/gold equivalent):
- **staging**: Raw data as-received from source systems; minimal transformation; high churn rate
- **transforms**: Cleaned, deduplicated, and conformed data; business logic applied; stable intermediate layer
- **marts**: Dimensional models (customers, products, dates) and fact tables (orders, transactions); optimized for analytics queries
- **monitoring**: Operational metadata separate from analytical data; enables pipeline observability without cluttering business schemas

**Why:** Separation of concerns reduces blast radius of data quality issues, enables independent refresh schedules, and provides clear data lineage for governance.

---

### 2. **Role-Based Access Control (RBAC)**
Three user groups are created with graduated permissions:

| Group | Schemas | Purpose | Typical Users |
|-------|---------|---------|----------------|
| **analytics_readers** | staging, transforms, marts, monitoring | Full pipeline visibility; data engineers and analysts exploring data | Data engineers, analytics engineers, data scientists |
| **bi_team** | marts only | BI tool connections; restricted to production-ready tables | BI developers, dashboard creators, report authors |
| **finance_team** | marts only | Financial reporting; restricted to approved metrics and dimensions | Finance analysts, controllers, CFO office |

**Why:** Prevents accidental queries on raw/staging data; ensures BI tools only consume validated marts; enables audit trails by group; reduces query load on staging/transforms layers.

---

### 3. **Default Privileges (Auto-Inheritance)**
The `ALTER DEFAULT PRIVILEGES` statements ensure that **any new table created in these schemas automatically inherits the group permissions** without manual re-granting.

**Why:** Prevents permission gaps when new tables are added; reduces operational overhead; ensures consistent governance as the warehouse grows.

---

### 4. **Redshift Spectrum Integration**
The external schema points to a Glue Catalog database (`ecommerce_raw`) in S3, allowing queries on raw files without loading them into Redshift.

**Why:** Enables cost-effective querying of large historical datasets; provides escape hatch for ad-hoc analysis without staging data; reduces storage costs for infrequently accessed raw data.

## Column Descriptions

**N/A** — This script creates schemas and permissions, not tables with columns. However, the schemas it creates will contain tables with columns defined in downstream scripts (e.g., `staging.orders`, `marts.dim_customers`).

## Data Quality & Edge Cases

### Assumptions
1. **IAM role exists**: The script assumes `arn:aws:iam::123456789012:role/RedshiftSpectrumRole` has already been created and has S3 read permissions.
2. **Glue Catalog is populated**: The external database `ecommerce_raw` must exist in the Glue Catalog with table definitions before Spectrum queries will work.
3. **Single-cluster deployment**: The script assumes one Redshift cluster; multi-cluster setups may require separate runs or cross-cluster permissions.
4. **Idempotent execution**: The `IF NOT EXISTS` clauses allow re-running without errors, but group creation will fail if groups already exist (non-idempotent).

### Potential Failure Modes

| Scenario | Impact | Mitigation |
|----------|--------|-----------|
| IAM role ARN is incorrect or role lacks S3 permissions | Spectrum queries fail with "Access Denied" | Verify IAM role exists and has `s3:GetObject` on the S3 bucket |
| Glue Catalog database doesn't exist | Spectrum schema creation succeeds but queries fail | Pre-create Glue Catalog database and run Glue Crawler on S3 data |
| User groups already exist (re-running script) | Script fails on `CREATE GROUP` statement | Drop groups first or use `CREATE GROUP IF NOT EXISTS` (Redshift doesn't support this; manual cleanup required) |
| Insufficient cluster permissions | Script fails with "permission denied" | Run as superuser or cluster admin |
| S3 bucket is in different AWS account | Spectrum cannot access data | Use cross-account IAM role with appropriate trust relationships |

### Edge Cases

- **Empty schemas**: Schemas are created but contain no tables initially; downstream ingestion scripts populate them.
- **Permission inheritance lag**: Default privileges apply only to tables created *after* the `ALTER DEFAULT PRIVILEGES` statement; existing tables must be granted permissions manually.
- **Group membership**: The script creates groups but does not add users to them; user assignment happens separately via `ALTER GROUP ... ADD USER` commands.

## Performance Notes

### Execution Performance
- **Execution time**: < 1 second (DDL operations are lightweight)
- **Resource impact**: Negligible; no compute or I/O required
- **Concurrency**: Safe to run in parallel with other DDL; no table locks

### Schema Design Implications

| Design Choice | Performance Impact | Rationale |
|---------------|-------------------|-----------|
| **Separate schemas** | Reduces query planning overhead; enables schema-level statistics | Allows independent VACUUM and ANALYZE per layer |
| **External schema (Spectrum)** | Slower than native tables (S3 latency); good for cold data | Avoids loading infrequently accessed raw data into expensive Redshift storage |
| **Default privileges** | Minimal overhead; applied at table creation time | Eliminates permission-checking bottlenecks at query time |

### Distribution & Sort Keys
This script does not define distribution or sort keys (those are defined in downstream table creation scripts). However:
- **Staging tables** should typically use `DISTSTYLE ALL` (small, temporary)
- **Transform tables** should use `DISTKEY` on join columns (e.g., `customer_id`)
- **Mart tables** should use `DISTKEY` on dimension keys and `SORTKEY` on date/time columns for time-series queries

## Dependencies

### Upstream
- **AWS IAM**: The `RedshiftSpectrumRole` must exist before this script runs
- **AWS Glue Catalog**: The `ecommerce_raw` database must be registered in Glue before Spectrum queries will work
- **Redshift cluster**: A running Redshift cluster with superuser credentials

### Downstream
**All data pipeline components depend on this script:**
- `data/ingest_*.sql` — Ingestion scripts assume `staging` schema exists
- `transforms/clean_*.sql` — Transformation scripts assume `transforms` schema exists
- `marts/dim_*.sql` and `marts/fact_*.sql` — Mart scripts assume `marts` schema exists
- `monitoring/pipeline_logs.sql` — Monitoring assumes `monitoring` schema exists
- BI tools (Tableau, Looker, etc.) — Assume `marts` schema and `bi_team` group permissions exist
- Data quality frameworks — Assume `monitoring` schema for logging

### External Dependencies
- **AWS IAM**: Role-based access control
- **AWS Glue Catalog**: Metadata for Spectrum external tables
- **S3**: Raw data storage for Spectrum queries
- **Redshift cluster**: Target infrastructure

## Maintenance & Operational Notes

### When to Re-run
- **Never** in production (schemas are persistent)
- **Once per new cluster** during provisioning
- **For testing**: Drop and recreate schemas in dev/test environments

### Manual Steps Required After Execution
```sql
-- Add users to groups (not automated by this script)
ALTER GROUP analytics_readers ADD USER analyst_user_1;
ALTER GROUP bi_team ADD USER bi_user_1;
ALTER GROUP finance_team ADD USER finance_user_1;

-- Verify Spectrum connectivity
SELECT * FROM spectrum.ecommerce_raw.<table_name> LIMIT 1;
```

### Monitoring & Validation
```sql
-- Verify schemas exist
SELECT * FROM pg_namespace WHERE nspname IN ('staging', 'transforms', 'marts', 'monitoring');

-- Verify groups exist
SELECT * FROM pg_group WHERE groname IN ('analytics_readers', 'bi_team', 'finance_team');

-- Verify default privileges
SELECT * FROM pg_default_acl WHERE defaclschema::regnamespace::text IN ('staging', 'transforms', 'marts');
```