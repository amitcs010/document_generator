-- ============================================================
-- Schema and permissions setup for the e-commerce warehouse
-- Run this once when setting up the Redshift cluster.
-- ============================================================

-- Create schemas
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS transforms;
CREATE SCHEMA IF NOT EXISTS marts;
CREATE SCHEMA IF NOT EXISTS monitoring;

-- Create groups
CREATE GROUP analytics_readers;
CREATE GROUP bi_team;
CREATE GROUP finance_team;

-- Grant schema usage
GRANT USAGE ON SCHEMA staging TO GROUP analytics_readers;
GRANT USAGE ON SCHEMA transforms TO GROUP analytics_readers;
GRANT USAGE ON SCHEMA marts TO GROUP analytics_readers;
GRANT USAGE ON SCHEMA marts TO GROUP bi_team;
GRANT USAGE ON SCHEMA marts TO GROUP finance_team;
GRANT USAGE ON SCHEMA monitoring TO GROUP analytics_readers;

-- Default privileges: any new tables are automatically readable
ALTER DEFAULT PRIVILEGES IN SCHEMA staging GRANT SELECT ON TABLES TO GROUP analytics_readers;
ALTER DEFAULT PRIVILEGES IN SCHEMA transforms GRANT SELECT ON TABLES TO GROUP analytics_readers;
ALTER DEFAULT PRIVILEGES IN SCHEMA marts GRANT SELECT ON TABLES TO GROUP analytics_readers;
ALTER DEFAULT PRIVILEGES IN SCHEMA marts GRANT SELECT ON TABLES TO GROUP bi_team;
ALTER DEFAULT PRIVILEGES IN SCHEMA marts GRANT SELECT ON TABLES TO GROUP finance_team;

-- External schema for Spectrum (S3 data)
CREATE EXTERNAL SCHEMA IF NOT EXISTS spectrum
FROM DATA CATALOG
DATABASE 'ecommerce_raw'
IAM_ROLE 'arn:aws:iam::123456789012:role/RedshiftSpectrumRole'
CREATE EXTERNAL DATABASE IF NOT EXISTS;
