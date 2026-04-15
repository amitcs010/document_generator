# Data Lineage

```mermaid
graph LR
    subgraph Sources["📊 Sources"]
        src_customers["raw_customers"]
        src_orders["raw_orders"]
        src_events["raw_events"]
    end

    subgraph Staging["🔄 Staging"]
        stg_customers["stg_raw_customers.sql"]
        stg_orders["stg_raw_orders.sql"]
        stg_events["stg_raw_events.sql"]
    end

    subgraph Transforms["⚙️ Transforms"]
        int_order_items["int_order_items.sql"]
        int_customer_sessions["int_customer_sessions.sql"]
    end

    subgraph Marts["📈 Marts"]
        dim_customers["dim_customers.sql"]
        dim_products["dim_products.sql"]
        fct_orders["fct_orders.sql"]
        fct_daily_revenue["fct_daily_revenue.sql"]
    end

    subgraph QA["✓ Quality Checks"]
        dq_checks["data_quality_checks.py"]
    end

    src_customers --> stg_customers
    src_orders --> stg_orders
    src_events --> stg_events

    stg_customers --> dim_customers
    stg_orders --> int_order_items
    stg_events --> int_customer_sessions

    int_order_items --> dim_products
    int_order_items --> fct_daily_revenue
    int_order_items --> fct_orders

    stg_customers --> fct_orders
    int_customer_sessions --> fct_orders
    stg_orders --> fct_orders

    stg_orders --> fct_daily_revenue

    fct_orders --> dim_customers

    int_order_items --> dq_checks
    int_customer_sessions --> dq_checks
    dim_customers --> dq_checks
    dim_products --> dq_checks
    fct_orders --> dq_checks
    fct_daily_revenue --> dq_checks
```

## Dependency Edges

| Source File | Target File | Via Table |
|---|---|---|
| `transforms/int_order_items.sql` | `macros/data_quality_checks.py` | `transforms.int_order_items` |
| `marts/dim_products.sql` | `macros/data_quality_checks.py` | `marts.dim_products` |
| `marts/fct_daily_revenue.sql` | `macros/data_quality_checks.py` | `marts.fct_daily_revenue` |
| `transforms/int_customer_sessions.sql` | `macros/data_quality_checks.py` | `transforms.int_customer_sessions` |
| `marts/dim_customers.sql` | `macros/data_quality_checks.py` | `marts.dim_customers` |
| `marts/fct_orders.sql` | `macros/data_quality_checks.py` | `marts.fct_orders` |
| `staging/stg_raw_customers.sql` | `marts/dim_customers.sql` | `staging.stg_raw_customers` |
| `marts/fct_orders.sql` | `marts/dim_customers.sql` | `marts.fct_orders` |
| `transforms/int_order_items.sql` | `marts/dim_products.sql` | `transforms.int_order_items` |
| `staging/stg_raw_orders.sql` | `marts/fct_daily_revenue.sql` | `staging.stg_raw_orders` |
| `transforms/int_order_items.sql` | `marts/fct_daily_revenue.sql` | `transforms.int_order_items` |
| `staging/stg_raw_customers.sql` | `marts/fct_orders.sql` | `staging.stg_raw_customers` |
| `transforms/int_customer_sessions.sql` | `marts/fct_orders.sql` | `transforms.int_customer_sessions` |
| `staging/stg_raw_orders.sql` | `marts/fct_orders.sql` | `staging.stg_raw_orders` |
| `transforms/int_order_items.sql` | `marts/fct_orders.sql` | `transforms.int_order_items` |
| `staging/stg_raw_events.sql` | `transforms/int_customer_sessions.sql` | `staging.stg_raw_events` |
| `staging/stg_raw_orders.sql` | `transforms/int_order_items.sql` | `staging.stg_raw_orders` |
