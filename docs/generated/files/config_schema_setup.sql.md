# config/schema_setup.sql Documentation

**Purpose**
Initializes the Redshift data warehouse schema architecture and access controls for an e-commerce analytics environment. Establishes four logical schemas (staging, transforms, marts, monitoring), creates three user groups with role-based permissions, and configures external S3 access via Redshift Spectrum.

**Inputs**
- Redshift cluster with IAM role `RedshiftSpectrumRole` configured
- S3-backed Glue catalog database `ecommerce_raw`

**Outputs**
- 4 schemas: `staging`, `transforms`, `marts`, `monitoring`
- 3 groups: `analytics_readers`, `bi_team`, `finance_team`
- External schema `spectrum` linked to S3 data catalog
- Default table-level SELECT permissions applied per schema/group

**Key Transformations**
- Maps user groups to schema access levels (analytics_readers: read-only across all schemas; bi_team & finance_team: marts-only access)
- Configures default privileges to auto-grant SELECT on future tables
- Establishes Spectrum integration for querying external S3 data

**Dependencies**
- Reads from: `data` (external S3 via Glue catalog `ecommerce_raw`)
- Requires: Pre-existing IAM role with S3 and Glue permissions

**Notes**
- Run once during cluster initialization; idempotent (uses `IF NOT EXISTS`)
- AWS account ID hardcoded (123456789012) — update for target environment
- Default privileges only apply to tables created after execution; existing tables require manual grants