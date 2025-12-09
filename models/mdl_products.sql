DROP TABLE IF EXISTS mdl_products;


CREATE TABLE IF NOT EXISTS matrl_mstr.products (
    product_id     BIGSERIAL PRIMARY KEY,
    product_name   TEXT,
    category       TEXT,
    price          NUMERIC(10,2),
    updated_at     TIMESTAMP DEFAULT NOW()
);


