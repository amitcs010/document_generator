Error after 3 attempts: 429 POST https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?%24alt=json%3Benum-encoding%3Dint: You exceeded your current quota, please check your plan and billing details. For more information on this error, head to: https://ai.google.dev/gemini-api/docs/rate-limits. To monitor your current usage, head to: https://ai.dev/usage?tab=rate-limit. 
* Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 5, model: gemini-2.5-flash
Please retry in 18.026117818s.

## Visual Data Lineage

![Complete Data Lineage](lineage_diagram.png)

*The diagram above shows the complete data lineage across all SQL files in the repository.*



## Detailed File Inventory

| # | File Name | Type | Purpose | Sources | Targets |
|---|-----------|------|---------|---------|----------|
| 1 | `src_products.sql` | script | Creates the 'products' table within the 'stage' sc | - | stage.products |
| 2 | `src_customers.sql` | script | This SQL script creates the 'customers' table in t | - | stage.customers |
| 3 | `src_sales.sql` | script | Creates the `stage.sales` table to store raw sales | - | stage.sales |
| 4 | `mdl_sales.sql` | script | Creates the `sales` table within the `sales_strat_ | - | sales_strat_plan.sales |
| 5 | `mdl_products.sql` | script | This SQL file creates the `matrl_mstr.products` ta | - | matrl_mstr.products, mdl_products |
| 6 | `mdl_customers.sql` | script | This SQL script drops a temporary table and then c | - | cust_mstr.customers |
| 7 | `sp_products.sql` | stored_procedure | stored_procedure SQL file | stage.products | matrl_mstr.products |
| 8 | `sp_sales.sql` | stored_procedure | stored_procedure SQL file | stage.sales | sales_strat_plan.sales |
| 9 | `sp_load_models.sql` | stored_procedure | stored_procedure SQL file | stage.customers | cust_mstr.customers |
| 10 | `sp_sales_cust_prod.sql` | view | view SQL file | cust_mstr.customers, matrl_mstr.products, sales_strat_plan.sales | - |


---
*Generated: 2025-12-09 04:51:42*
*Files: 10 | Tables: 6 | Relationships: 3*
