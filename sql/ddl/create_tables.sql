-- sql/ddl/create_tables.sql
-- ═══════════════════════════════════════════════════════════
-- PURPOSE: Create all tables across raw, staging, warehouse
--
-- Run AFTER create_schemas.sql
-- Safe to re-run (IF NOT EXISTS prevents errors)
--
-- DECISIONS BASED ON DATA DISCOVERY (Stage 3):
--   products → flat except rating.rate + rating.count
--   carts    → products nested list → explode in staging
--   users    → deeply nested → flatten in staging
--              password field found → NEVER stored (security)
-- ═══════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════
-- RAW SCHEMA — Bronze Layer
--
-- Rule 1: Store EXACTLY what the API sent, nothing more
-- Rule 2: Never modify data in this layer
-- Rule 3: Never delete from this layer
-- Rule 4: This is your audit trail and safety net
--
-- WHY JSONB for raw_data?
-- Discovery showed each endpoint returns a JSON object
-- JSONB stores it exactly as received:
--   → API adds new field tomorrow? Captured automatically ✅
--   → Something breaks in staging? Raw data still intact ✅
--   → Need to reprocess? Replay from raw ✅
--
-- WHY JSONB not JSON?
--   JSON  = stored as plain text, re-parsed every query (slow)
--   JSONB = stored as binary, indexed, faster queries ✅
--
-- WHY loaded_at?
--   Records WHEN we pulled this from the API
--   Answers: "what did the API send on Tuesday at 3am?"
--   Critical for debugging pipeline issues
-- ═══════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS raw.products (
    id          SERIAL       PRIMARY KEY,
    raw_data    JSONB        NOT NULL,
    loaded_at   TIMESTAMP    NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS raw.carts (
    id          SERIAL       PRIMARY KEY,
    raw_data    JSONB        NOT NULL,
    loaded_at   TIMESTAMP    NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS raw.users (
    id          SERIAL       PRIMARY KEY,
    raw_data    JSONB        NOT NULL,
    loaded_at   TIMESTAMP    NOT NULL DEFAULT NOW()
);


-- ═══════════════════════════════════════════════════════════
-- STAGING SCHEMA — Silver Layer
--
-- Rule 1: Flat, typed, cleaned — no nested objects
-- Rule 2: Truncated and reloaded on every pipeline run
-- Rule 3: No history kept here (warehouse handles history)
-- Rule 4: This is a processing layer, not a storage layer
--
-- WHY truncate and reload every run?
-- Staging is a temporary workspace
-- Think of it like a whiteboard:
--   Every pipeline run wipes it clean
--   Writes fresh data from raw
--   Warehouse then reads from staging
-- No need to track history here — warehouse does that
-- ═══════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────
-- staging.products
--
-- Discovery findings:
--   Fields: id, title, price, description,
--           category, image, rating.rate, rating.count
--   Nulls:  none found → all can be NOT NULL except description
--   Types:  price=float64 → NUMERIC(10,2)
--           rating.rate=float → NUMERIC(3,1)
--           rating.count=int → INTEGER
--
-- WHY NUMERIC(10,2) not FLOAT for price?
--   FLOAT = floating point arithmetic, imprecise:
--   109.95 + 0.10 = 110.05000000000001 in FLOAT ❌
--   Money must be exact → NUMERIC(10,2) always ✅
--   NUMERIC(10,2) = up to 10 digits, exactly 2 decimal places
--
-- WHY TEXT not VARCHAR for strings?
--   VARCHAR(50) breaks if API sends 51 characters ❌
--   TEXT = unlimited, never breaks ✅
--   Add length validation in Python transform logic instead
--
-- WHY keep source_id separate from our id?
--   id       = OUR surrogate key (SERIAL, we control it)
--   source_id = API's id (we don't control it)
--   Keeping both lets us trace any row back to the API
-- ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS staging.products (
    id              SERIAL          PRIMARY KEY,
    source_id       INTEGER         NOT NULL,
    title           TEXT            NOT NULL,
    price           NUMERIC(10,2)   NOT NULL,
    category        TEXT            NOT NULL,
    description     TEXT,
    image_url       TEXT,
    rating_rate     NUMERIC(3,1),
    rating_count    INTEGER,
    loaded_at       TIMESTAMP       NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────
-- staging.users
--
-- Discovery findings:
--   Fields: id, email, username, password,
--           name.firstname, name.lastname,
--           address.street, address.city,
--           address.zipcode,
--           address.geolocation.lat,
--           address.geolocation.long,
--           phone
--
--   Nulls:    none found
--   Notable:  email unique, username unique
--             password EXISTS → never stored (security)
--             geolocation needs high decimal precision
--
-- WHY is password excluded?
--   Security principle: never store credentials
--   you don't need to store
--   Our pipeline analyses purchase behaviour
--   We have zero business reason to store passwords
--   Storing them creates liability and security risk ❌
--
-- WHY NUMERIC(9,6) for lat/lng?
--   Geolocation coordinates look like: 40.718776
--   Need 6 decimal places for street-level precision
--   NUMERIC(9,6) = up to 9 digits, 6 decimal places
--   e.g. -73.998672 fits perfectly ✅
-- ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS staging.users (
    id              SERIAL          PRIMARY KEY,
    source_id       INTEGER         NOT NULL,
    email           TEXT            NOT NULL,
    username        TEXT            NOT NULL,
    first_name      TEXT,
    last_name       TEXT,
    phone           TEXT,
    address_street  TEXT,
    address_city    TEXT,
    address_zip     TEXT,
    address_lat     NUMERIC(9,6),
    address_lng     NUMERIC(9,6),
    loaded_at       TIMESTAMP       NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────
-- staging.carts
--
-- Discovery findings:
--   Fields: id, userId, date, products
--   products = LIST of {productId, quantity}
--   One cart has MULTIPLE products
--
-- WHY one row per product per cart?
--   API sends this:
--   cart_id=1, userId=1, products=[
--     {productId: 1, quantity: 2},
--     {productId: 4, quantity: 1}
--   ]
--
--   We store this as TWO rows:
--   cart_id=1, user_id=1, product_id=1, quantity=2
--   cart_id=1, user_id=1, product_id=4, quantity=1
--
--   This is called EXPLODING the nested list
--
--   WHY explode?
--   Business question: "how many times was product 1 ordered?"
--   With list:    impossible to query directly ❌
--   After explode: SELECT COUNT(*) WHERE product_id=1 ✅
--
-- WHY DATE not TIMESTAMP for cart_date?
--   API sends "2020-03-02" — date only, no time component
--   Storing as DATE is more accurate than TIMESTAMP
--   Never store more precision than the data actually has
-- ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS staging.carts (
    id                  SERIAL      PRIMARY KEY,
    cart_source_id      INTEGER     NOT NULL,
    user_source_id      INTEGER     NOT NULL,
    product_source_id   INTEGER     NOT NULL,
    quantity            INTEGER     NOT NULL,
    cart_date           DATE        NOT NULL,
    loaded_at           TIMESTAMP   NOT NULL DEFAULT NOW()
);


-- ═══════════════════════════════════════════════════════════
-- WAREHOUSE SCHEMA — Gold Layer
--
-- Rule 1: Business-ready, history preserved forever
-- Rule 2: History NEVER deleted, only expired (SCD Type 2)
-- Rule 3: Always query with is_current=TRUE for latest data
-- Rule 4: Use surrogate keys, never natural keys as FK
--
-- DIMENSIONAL MODELLING:
-- Two types of tables:
--
-- DIMENSION tables = the WHO and WHAT
--   dim_products → WHAT was sold
--   dim_users    → WHO bought it
--   These have history (SCD Type 2)
--
-- FACT tables = the NUMBERS and EVENTS
--   fact_orders  → HOW MANY, HOW MUCH, WHEN
--   These reference dimensions via surrogate keys
--
-- This pattern is called a STAR SCHEMA:
--   fact table in the middle
--   dimension tables around it like points of a star
-- ═══════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────
-- warehouse.dim_products — SCD Type 2
--
-- WHY SCD Type 2 for products?
-- Discovery showed products have price and category
-- Both can change over time:
--   Jan: Backpack costs $109.95
--   Mar: Price drops to $89.95 (sale)
--   Aug: Price rises to $129.95
--
-- Business question: "what did this backpack cost in Feb?"
-- Without SCD2: only latest price stored → impossible ❌
-- With SCD2:    all versions stored → $109.95 ✅
--
-- SCD Type 2 columns:
--   valid_from  = when this version became active
--   valid_to    = when this version was replaced
--                 9999-12-31 = still active (open ended)
--   is_current  = TRUE for latest version only
--                 faster than filtering by valid_to date
--
-- WHY 9999-12-31 instead of NULL for valid_to?
--   NULL means "unknown" in SQL → ambiguous ❌
--   9999-12-31 means "no end date, still active" → clear ✅
--   Also easier to query:
--   WHERE valid_to = '9999-12-31'  ← clear intent
--   WHERE valid_to IS NULL         ← ambiguous
--
-- WHY product_sk (surrogate key)?
--   source_id comes from FakeStoreAPI (we don't control it)
--   If API reuses id=1 for a different product:
--   Without surrogate key → history corrupted ❌
--   With surrogate key → each version gets unique sk ✅
--   product_sk=1001 → Backpack v1 at $109.95
--   product_sk=1002 → Backpack v2 at $89.95
-- ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS warehouse.dim_products (
    product_sk      SERIAL          PRIMARY KEY,
    source_id       INTEGER         NOT NULL,
    title           TEXT            NOT NULL,
    price           NUMERIC(10,2)   NOT NULL,
    category        TEXT            NOT NULL,
    description     TEXT,
    image_url       TEXT,
    rating_rate     NUMERIC(3,1),
    rating_count    INTEGER,
    valid_from      DATE            NOT NULL,
    valid_to        DATE            NOT NULL DEFAULT '9999-12-31',
    is_current      BOOLEAN         NOT NULL DEFAULT TRUE
);

-- ─────────────────────────────────────────────────────────
-- warehouse.dim_users — SCD Type 2
--
-- WHY SCD Type 2 for users?
-- Discovery showed users have address fields
-- Addresses change:
--   User moves from Sydney to Melbourne
--   Old address must be preserved for historical orders
--
-- Business question: "where did this user live when
--                     they placed this order in January?"
-- Without SCD2: address overwritten → impossible ❌
-- With SCD2:    old address preserved → Sydney ✅
--
-- WHY exclude password here too?
-- Same security rule as staging:
-- We have zero business reason to store passwords
-- Our warehouse is for analytics, not authentication
-- ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS warehouse.dim_users (
    user_sk         SERIAL      PRIMARY KEY,
    source_id       INTEGER     NOT NULL,
    email           TEXT        NOT NULL,
    username        TEXT        NOT NULL,
    first_name      TEXT,
    last_name       TEXT,
    phone           TEXT,
    address_street  TEXT,
    address_city    TEXT,
    address_zip     TEXT,
    valid_from      DATE        NOT NULL,
    valid_to        DATE        NOT NULL DEFAULT '9999-12-31',
    is_current      BOOLEAN     NOT NULL DEFAULT TRUE
);

-- ─────────────────────────────────────────────────────────
-- warehouse.fact_orders
--
-- WHY is this a FACT table not a dimension?
-- Fact tables store MEASURABLE EVENTS:
--   "User 5 ordered 2 units of product 3 on March 12"
--   The NUMBERS are: quantity=2, price=109.95, total=219.90
--   The EVENT is:    the order happening
--
-- Dimension tables store DESCRIPTIVE CONTEXT:
--   Who is user 5? (dim_users)
--   What is product 3? (dim_products)
--
-- Fact + Dimensions together answer business questions:
--   "How much revenue came from Sydney users last month?"
--   → JOIN fact_orders → dim_users (city=Sydney)
--   → SUM(total_price) WHERE order_date last month
--
-- WHY store unit_price in fact table?
-- dim_products price changes over time (SCD2)
-- We need the price AT THE TIME of the order
-- Not the current price
--
-- Example:
--   Order placed Jan 15: Backpack at $109.95
--   Price changed Feb 1: now $89.95
--   fact_orders.unit_price = $109.95 (preserved forever) ✅
--   dim_products current price = $89.95 (latest version)
--
-- WHY product_sk and user_sk not source_id?
-- Surrogate keys point to EXACT VERSION of product/user
-- that existed at order time
-- source_id alone cannot tell you which version ❌
--
-- FOREIGN KEY constraints:
-- Ensures every order references a real product and user
-- Prevents orphaned records (orders with no product) ❌
-- ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS warehouse.fact_orders (
    order_sk        SERIAL          PRIMARY KEY,
    cart_source_id  INTEGER         NOT NULL,
    product_sk      INTEGER         NOT NULL
                        REFERENCES warehouse.dim_products(product_sk),
    user_sk         INTEGER         NOT NULL
                        REFERENCES warehouse.dim_users(user_sk),
    quantity        INTEGER         NOT NULL,
    unit_price      NUMERIC(10,2)   NOT NULL,
    total_price     NUMERIC(10,2)   NOT NULL,
    order_date      DATE            NOT NULL,
    loaded_at       TIMESTAMP       NOT NULL DEFAULT NOW()
);


-- ═══════════════════════════════════════════════════════════
-- INDEXES
--
-- WHY add indexes?
-- Without index: PostgreSQL reads EVERY row to find matches
--               called a sequential scan
--               fast for 100 rows, very slow for 1 million rows
--
-- With index:   PostgreSQL jumps directly to matching rows
--               called an index scan
--               fast regardless of table size
--
-- We only index columns used in WHERE clauses most often:
-- Over-indexing slows down INSERT/UPDATE operations
-- Under-indexing slows down SELECT queries
-- Index the columns your queries actually filter on ✅
-- ═══════════════════════════════════════════════════════════

-- dim_products: most common query patterns
-- "give me current version of product X"
-- "give me all current products in category Y"
CREATE INDEX IF NOT EXISTS idx_dim_products_source_id
    ON warehouse.dim_products(source_id);

CREATE INDEX IF NOT EXISTS idx_dim_products_is_current
    ON warehouse.dim_products(is_current);

CREATE INDEX IF NOT EXISTS idx_dim_products_category
    ON warehouse.dim_products(category);

-- dim_users: most common query patterns
-- "give me current version of user X"
-- "give me all current users in city Y"
CREATE INDEX IF NOT EXISTS idx_dim_users_source_id
    ON warehouse.dim_users(source_id);

CREATE INDEX IF NOT EXISTS idx_dim_users_is_current
    ON warehouse.dim_users(is_current);

-- fact_orders: most common query patterns
-- "give me all orders in date range"
-- "give me all orders for product X"
-- "give me all orders for user Y"
CREATE INDEX IF NOT EXISTS idx_fact_orders_order_date
    ON warehouse.fact_orders(order_date);

CREATE INDEX IF NOT EXISTS idx_fact_orders_product_sk
    ON warehouse.fact_orders(product_sk);

CREATE INDEX IF NOT EXISTS idx_fact_orders_user_sk
    ON warehouse.fact_orders(user_sk);