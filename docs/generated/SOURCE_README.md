# document_generator

## Overview

This repository contains a comprehensive **e-commerce data warehouse** built on **Amazon Redshift**, designed to transform raw operational data into analytics-ready dimensional and fact tables. The pipeline ingests customer, product, order, and clickstream data from multiple sources, applies rigorous data quality checks, and delivers business intelligence insights through well-structured marts. It solves critical business problems including customer segmentation via RFM analysis, revenue attribution across channels and geographies, and session-level user behavior analytics.

## Architecture

```
Raw Sources (CRM, S3, Clickstream) 
    ↓
[Staging Layer] - Data cleaning, deduplication, PII masking
    ↓
[Transform Layer] - Business logic, sessionization, enrichment
    ↓
[Marts Layer] - Dimensional & fact tables optimized for BI
    ↓
BI Tools / Analytics Dashboards
```

**Layer Descriptions:**

- **Staging**: Ingests raw data from external sources (S3, CRM systems, event streams), applies basic transformations, deduplication, and PII masking. Creates a normalized foundation for downstream processing.
- **Transform**: Applies complex business logic including sessionization, aggregations, and cross-domain joins. Produces intermediate tables that combine multiple staging sources.
- **Marts**: Builds analytics-ready dimensional and fact tables following Kimball methodology. Optimized for BI queries with pre-computed metrics and aggregations.
- **Config & Utilities**: Manages schema initialization, user permissions, and automated data quality validation post-ETL.

## Repository Structure

```
amitcs010/document_generator/
├── config/
│   └── schema_setup.sql              # Redshift warehouse initialization & user groups
├── macros/
│   └── data_quality_checks.py        # Automated DQ validation & alerting
├── staging/
│   ├── stg_raw_customers.sql         # CRM customer data transformation
│   ├── stg_raw_events.sql            # Clickstream event normalization
│   ├── stg_raw_orders.sql            # Order data cleaning & optimization
│   └── stg_raw_products.sql          # Product inventory staging (SCD Type 1)
├── transforms/
│   ├── int_customer_sessions.sql     # Session aggregation & attribution
│   └── int_order_items.sql           # Order line item enrichment
├── marts/
│   ├── dim_customers.sql             # Customer dimension w/ RFM & LTV
│   ├── dim_products.sql              # Product dimension w/ performance metrics
│   ├── fct_daily_revenue.sql         # Daily revenue fact table
│   └── fct_orders.sql                # Order fact table (orders + line items + sessions)
└── docs/
    └── generated/                    # Auto-generated documentation
```

## Components

### Staging Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `stg_raw_customers.sql` | Deduplicates CRM records, masks PII (email, phone), standardizes formats | CRM System | `int_customer_sessions`, `dim_customers` |
| `stg_raw_events.sql` | Normalizes JSON clickstream events, deduplicates by event_id, distributes on event_id | Event Stream (S3) | `int_customer_sessions` |
| `stg_raw_orders.sql` | Cleans S3 order data, filters test orders, optimizes for Redshift distribution | S3 Data Lake | `int_order_items`, `fct_orders` |
| `stg_raw_products.sql` | Applies SCD Type 1 methodology to product inventory, maintains current state | Product Catalog | `int_order_items`, `dim_products` |

### Transform Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `int_customer_sessions.sql` | Sessionizes clickstream events, computes session metrics (duration, page views), applies attribution models | `stg_raw_events`, `stg_raw_customers` | `fct_orders`, `dim_customers` |
| `int_order_items.sql` | Joins order line items with product data, calculates item-level revenue, margin, discount metrics | `stg_raw_orders`, `stg_raw_products` | `fct_orders`, `fct_daily_revenue` |

### Marts Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `dim_customers.sql` | Customer dimension with RFM scoring (Recency, Frequency, Monetary), lifetime value, segmentation flags | `stg_raw_customers`, `int_customer_sessions` | BI Dashboards |
| `dim_products.sql` | Product dimension enriched with aggregated sales performance (total revenue, units sold, avg rating) | `stg_raw_products`, `int_order_items` | BI Dashboards |
| `fct_daily_revenue.sql` | Fact table aggregating daily revenue by product category, sales channel, and country with drill-down capability | `int_order_items` | BI Dashboards |
| `fct_orders.sql` | Comprehensive order fact table combining orders, line items, customers, and sessions for multi-dimensional analysis | `stg_raw_orders`, `int_order_items`, `stg_raw_customers`, `int_customer_sessions` | BI Dashboards |

### Utilities & Config

| Component | Description |
|-----------|-------------|
| `config/schema_setup.sql` | Initializes Redshift warehouse schemas, creates user groups, sets permissions for staging/transform/marts layers |
| `macros/data_quality_checks.py` | Executes post-ETL data quality validations (null checks, uniqueness, referential integrity), logs results, triggers failure alerts |

## Data Lineage

```
CRM System
    ↓
stg_raw_customers ──┐
                    ├──→ int_customer_sessions ──┐
stg_raw_events ─────┘                            ├──→ fct_orders ──→ BI Dashboards
                                                 │
S3 Order Data                                    │
    ↓                                            │
stg_raw_orders ──┐                              │
                 ├──→ int_order_items ──────────┤
Product Catalog  │                              │
    ↓            │                              │
stg_raw_products ┘                              ├──→ fct_daily_revenue ──→ BI Dashboards
                                                │
                                                └──→ dim_customers ──→ BI Dashboards
                                                
                                                └──→ dim_products ──→ BI Dashboards
```

## Data Flow

**End-to-End Process:**

1. **Ingestion**: Raw data arrives from three sources:
   - CRM system → customer records
   - S3 data lake → order transactions
   - Event stream → clickstream JSON events
   - Product catalog → inventory & metadata

2. **Staging**: Each source is independently transformed:
   - Deduplication and validation
   - PII masking for sensitive fields
   - Format standardization and type casting
   - Distribution key optimization for Redshift

3. **Transformation**: Intermediate tables combine and enrich data:
   - Clickstream events are sessionized with user attribution
   - Order line items are joined with product dimensions
   - Session and order metrics are pre-computed

4. **Marts**: Analytics-ready tables are built:
   - Dimensional tables (customers, products) with business metrics
   - Fact tables (orders, daily revenue) optimized for BI queries

5. **Quality Assurance**: Post-ETL validation ensures:
   - No null values in key columns
   - Referential integrity across dimensions and facts
   - Row count reconciliation with source systems
   - Alerts triggered on validation failures

6. **Consumption**: BI tools query marts for dashboards, reports, and ad-hoc analysis

## Key Business Metrics

- **Customer Lifetime Value (LTV)**: Total revenue attributed to each customer
- **RFM Segmentation**: Recency, Frequency, Monetary scoring for customer prioritization
- **Daily Revenue by Channel**: Revenue aggregated by sales channel and geography
- **Product Performance**: Units sold, revenue, and margin per product
- **Session Metrics**: Session duration, page views, conversion attribution
- **Order Metrics**: Order value, item count, discount impact, margin analysis

## Getting Started

### Prerequisites

- **Redshift Cluster Access**: Active connection to Redshift cluster with appropriate IAM role
- **Permissions**: User must have `CREATE TABLE`, `INSERT`, `SELECT` on staging/transform/marts schemas
- **SQL Client**: psql, DBeaver, or Redshift Query Editor
- **S3 Access**: Read permissions on source data buckets (for COPY commands)

### Running the ETL

1. **Initialize warehouse** (one-time setup):
   ```sql
   psql -h <redshift-endpoint> -U <admin-user> -d <database> -f config/schema_setup.sql
   ```

2. **Execute staging layer**:
   ```sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f staging/stg_raw_customers.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f staging/stg_raw_events.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f staging/stg_raw_orders.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f staging/stg_raw_products.sql
   ```

3. **Execute transform layer**:
   ```sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f transforms/int_customer_sessions.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f transforms/int_order_items.sql
   ```

4. **Execute marts layer**:
   ```sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f marts/dim_customers.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f marts/dim_products.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f marts/fct_daily_revenue.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f marts/fct_orders.sql
   ```

5. **Run data quality checks**:
   ```bash
   python macros/data_quality_checks.py --config config/dq_config.yaml
   ```

### Adding New Components

1. **Create new staging table**: Add SQL file to `staging/` following naming convention `stg_raw_<source>.sql`
2. **Create intermediate table**: Add SQL file to `transforms/` following naming convention `int_<business_concept>.sql`
3. **Create mart table**: Add SQL file to `marts/` following naming convention `dim_<entity>.sql` or `fct_<event>.sql`
4. **Update data quality checks**: Add validation rules to `macros/data_quality_checks.py`
5. **Document lineage**: Update dependency graph in component headers

## Documentation

- **Full Technical Documentation**: [`docs/generated/FULL_DOCUMENTATION.md`](docs/generated/FULL_DOCUMENTATION.md)
- **Component Index**: [`docs/generated/COMPONENT_INDEX.md`](docs/generated/COMPONENT_INDEX.md)
- **Data Lineage Diagram**: [`docs/generated/DATA_LINEAGE.md`](docs/generated/DATA_LINEAGE.md)
- **Per-File Documentation**: [`docs/generated/files/`](docs/generated/files/)

## Auto-Generated

This README was auto-generated by **RepoMigrator**. Push any commit to regenerate documentation.

**Last updated**: 2026-04-14 21:11:55 UTC

---

**Repository**: [amitcs010/document_generator](https://github.com/amitcs010/document_generator)  
**Platform**: Amazon Redshift  
**Language**: SQL, Python