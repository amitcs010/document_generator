CREATE TABLE IF NOT EXISTS stage.sales (
    sale_id        BIGSERIAL PRIMARY KEY,
    customer_id    BIGINT NOT NULL,
    product_id     BIGINT NOT NULL,
    quantity       INTEGER NOT NULL,
    price          NUMERIC(10,2) NOT NULL,
    sale_date      TIMESTAMP NOT NULL
);
