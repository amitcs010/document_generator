CREATE TABLE IF NOT EXISTS src_products (
    product_id     BIGSERIAL PRIMARY KEY,
    product_name   TEXT,
    category       TEXT,
    price          NUMERIC(10,2),
    updated_at     TIMESTAMP DEFAULT NOW()
);
