CREATE TABLE IF NOT EXISTS stage.customers (
    customer_id    BIGSERIAL PRIMARY KEY,
    first_name     TEXT,
    last_name      TEXT,
    email          TEXT,
    region         TEXT,
    created_at     TIMESTAMP DEFAULT NOW()
);
