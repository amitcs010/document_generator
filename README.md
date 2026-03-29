# E-Commerce Data Warehouse (Redshift)

This repository contains the SQL ETL pipeline for our e-commerce analytics platform running on Amazon Redshift.

## Structure

```
staging/          -- Raw data ingestion and cleaning
transforms/       -- Business logic and intermediate tables
marts/            -- Final fact and dimension tables for BI
macros/           -- Reusable SQL snippets
config/           -- Table DDLs and permissions
```

## Data Flow

```
Raw S3 Parquet → staging.stg_* → transforms.int_* → marts.fct_* / marts.dim_*
```

## Key Tables

| Table | Description |
|-------|-------------|
| `marts.fct_orders` | Order-level fact table with revenue metrics |
| `marts.fct_daily_revenue` | Daily revenue rollup by product category |
| `marts.dim_customers` | Customer dimension with segmentation |
| `marts.dim_products` | Product catalog dimension |
| `staging.stg_raw_orders` | Cleaned raw orders from S3 |
| `staging.stg_raw_events` | Cleaned clickstream events |

## Schedule

All ETL runs nightly at 02:00 UTC via Airflow.
