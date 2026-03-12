# Retail ETL Pipeline

A production-grade ETL pipeline built with Python, PostgreSQL, Airflow, and Docker.
Pulls retail data from FakeStoreAPI and loads it into a warehouse using medallion architecture.

Built as a portfolio project to demonstrate data engineering skills.

---

## Architecture

```
FakeStoreAPI
     ↓
  EXTRACT
  raw schema (JSONB)
     ↓
 TRANSFORM
 staging schema (flat, typed)
     ↓
   LOAD
 warehouse schema (star schema)
     ↓
 dim_products   dim_users
        ↘      ↙
       fact_orders
```

**Medallion Architecture:**
- **Raw** — stores original API responses as JSONB, unchanged
- **Staging** — cleaned, flattened, typed data ready for loading
- **Warehouse** — star schema with SCD Type 2 dimensions and fact table

---

## Tech Stack

| Tool | Purpose |
|------|---------|
| Python 3.11 | Pipeline logic |
| PostgreSQL 15 | Database (raw, staging, warehouse) |
| SQLAlchemy 2.0 | Database connection pooling |
| Pydantic v2 | Config validation |
| Tenacity | API retry logic |
| Apache Airflow | Pipeline scheduling |
| Docker + Compose | Containerisation |
| GitHub Actions | CI/CD |
| pytest | Automated testing |

---

## Project Structure

```
retail_etl/
├── etl/
│   ├── extract/
│   │   ├── api_client.py          → HTTP client with retry logic
│   │   └── fakestore_extractor.py → pulls products, carts, users
│   ├── transform/
│   │   ├── products_transform.py  → flatten rating dict
│   │   ├── carts_transform.py     → explode products list
│   │   └── users_transform.py     → flatten name + address
│   ├── load/
│   │   ├── products_load.py       → SCD Type 2 → dim_products
│   │   ├── users_load.py          → SCD Type 2 → dim_users
│   │   └── orders_load.py         → append only → fact_orders
│   └── utils/
│       ├── config.py              → pydantic settings
│       ├── db.py                  → connection pool + context manager
│       └── logger.py              → structured logging
├── dags/
│   └── retail_etl_dag.py          → Airflow DAG (daily at 2am)
├── sql/ddl/
│   ├── create_schemas.sql         → raw, staging, warehouse
│   └── create_tables.sql          → all 9 tables
├── tests/
│   ├── unit/                      → 39 tests, no database needed
│   └── integration/               → 4 tests, uses test database
├── run_pipeline.py                → single entry point
├── Dockerfile
├── docker-compose.yml
└── .github/workflows/ci.yml       → GitHub Actions CI
```

---

## Data Sources

**FakeStoreAPI** — `https://fakestoreapi.com`

| Endpoint | Records | Notes |
|----------|---------|-------|
| /products | 20 | Nested rating dict |
| /carts | 7 | Products list → exploded to rows |
| /users | 10 | Nested name, address, geolocation |

---

## Database Schema

### Raw Layer
Stores original API responses unchanged:
```sql
raw.products  (id, raw_data JSONB, loaded_at)
raw.carts     (id, raw_data JSONB, loaded_at)
raw.users     (id, raw_data JSONB, loaded_at)
```

### Staging Layer
Flat, typed, cleaned:
```sql
staging.products  (source_id, title, price, category, ...)
staging.carts     (cart_source_id, user_source_id, product_source_id, quantity, cart_date)
staging.users     (source_id, email, username, first_name, last_name, address_*, ...)
```

### Warehouse Layer
Star schema, business-ready:
```sql
warehouse.dim_products  (product_sk, source_id, title, price, category, valid_from, valid_to, is_current)
warehouse.dim_users     (user_sk, source_id, email, username, address_*, valid_from, valid_to, is_current)
warehouse.fact_orders   (order_sk, cart_source_id, product_sk, user_sk, quantity, unit_price, total_price, order_date)
```

---

## Key Engineering Decisions

### SCD Type 2 for Dimensions
Dimensions use Slowly Changing Dimension Type 2 to preserve history:
```
Price changes: $109.95 → $89.95
Old row: valid_to=today,     is_current=FALSE  ← preserved forever
New row: valid_from=today,   is_current=TRUE   ← current version

Business question answered:
"What did this product cost in January?" ✅
```

### Append Only for Facts
Orders are immutable historical events — never updated, only appended:
```
"User 1 bought 4 units of product 1 on March 2"
This fact never changes → append only ✅
```

### Connection Pooling
SQLAlchemy QueuePool with pool_size=5, max_overflow=10, pool_pre_ping=True.
Reuses connections instead of opening a new one per query.

### Fail Fast
Config validation at startup via Pydantic — crashes immediately with a clear
error if any required environment variable is missing.

### Password Never Stored
User passwords are excluded at the transform layer and never reach staging
or warehouse. Verified by automated tests.

---

## Getting Started

### Prerequisites
- Python 3.11
- PostgreSQL 15
- Git

### Local Setup

```bash
# Clone the repo
git clone https://github.com/phildinh/retail-etl-pipeline.git
cd retail-etl-pipeline

# Create virtual environment
python -m venv venv
venv\Scripts\activate        # Windows
source venv/bin/activate     # Mac/Linux

# Install dependencies
pip install -r requirements.txt

# Create environment file
cp .env.example .env.dev
# Edit .env.dev with your database credentials
```

### Database Setup

```bash
# Create databases in PostgreSQL
createdb retail_etl_dev
createdb retail_etl_test

# Run DDL
psql -U etl_user -d retail_etl_dev  -f sql/ddl/create_schemas.sql
psql -U etl_user -d retail_etl_dev  -f sql/ddl/create_tables.sql
psql -U etl_user -d retail_etl_test -f sql/ddl/create_schemas.sql
psql -U etl_user -d retail_etl_test -f sql/ddl/create_tables.sql
```

### Run The Pipeline

```bash
python run_pipeline.py
```

Expected output:
```
═══════════════════════════════════════════════════════
  RETAIL ETL PIPELINE STARTED
═══════════════════════════════════════════════════════
  ✅  Extract — FakeStoreAPI      (products=20, carts=7, users=10)
  ✅  Transform — Products
  ✅  Transform — Carts
  ✅  Transform — Users
  ✅  Load — dim_products (SCD2)  (inserted=20)
  ✅  Load — dim_users (SCD2)     (inserted=10)
  ✅  Load — fact_orders          (inserted=14)
═══════════════════════════════════════════════════════
  Total time: 2.7 seconds
═══════════════════════════════════════════════════════
```

---

## Running With Docker

```bash
# Build and run everything (database + pipeline)
docker compose up

# Connect to database
# host: localhost | port: 5433 | db: retail_etl_dev
# user: etl_user  | password: 2011

# Stop everything
docker compose down
```

---

## Testing

```bash
# Unit tests (no database needed, ~1 second)
pytest tests/unit/ -v

# Integration tests (requires retail_etl_test database)
$env:ENV="test"; pytest tests/integration/ -v  # Windows
ENV=test pytest tests/integration/ -v          # Mac/Linux
```

**Test coverage:**

| File | Tests | What It Covers |
|------|-------|----------------|
| test_products_transform.py | 9 | Flatten, rename, type cast |
| test_carts_transform.py | 13 | Explode, date parse, key validation |
| test_users_transform.py | 17 | Flatten, password excluded, bad geo |
| test_pipeline_integration.py | 4 | Full read/write cycle, no duplicates |
| **Total** | **43** | |

---

## CI/CD

GitHub Actions runs all 39 unit tests automatically on every push:

```
Push code
    ↓
GitHub spins up Ubuntu VM
    ↓
Install Python 3.11 + dependencies
    ↓
pytest tests/unit/
    ↓
Green ✅ → merge allowed
Red   ❌ → merge blocked
```

See `.github/workflows/ci.yml`.

---

## Airflow DAG

Daily schedule at 2am. Parallel transforms for faster execution:

```
extract
    ↓
transform_products  transform_carts  transform_users  (parallel)
    ↓                                      ↓
load_dim_products                    load_dim_users   (parallel)
         ↘                           ↙
           load_fact_orders
```

Retries=2 with 5 minute delay for API resilience.

---

## Analytics Query

After pipeline runs, query the warehouse:

```sql
SELECT
    fo.order_date,
    dp.category,
    COUNT(DISTINCT fo.cart_source_id) AS total_orders,
    SUM(fo.quantity)                  AS total_units,
    ROUND(SUM(fo.total_price), 2)     AS total_revenue
FROM warehouse.fact_orders fo
JOIN warehouse.dim_products dp ON fo.product_sk = dp.product_sk
JOIN warehouse.dim_users du     ON fo.user_sk    = du.user_sk
GROUP BY fo.order_date, dp.category
ORDER BY total_revenue DESC;
```

---

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| ENV | Environment name | dev / test / prod |
| DB_SERVER | Database host | localhost |
| DB_PORT | Database port | 5432 |
| DB_NAME | Database name | retail_etl_dev |
| DB_USER | Database user | etl_user |
| DB_PASSWORD | Database password | — |
| API_BASE_URL | FakeStoreAPI base URL | https://fakestoreapi.com |

Copy `.env.example` and fill in your values. Never commit `.env.*` files.

---

## Stages Built

| Stage | Description |
|-------|-------------|
| 1 | Project foundation — structure, git, venv |
| 2 | Utilities — config, database, logger |
| 3 | Data discovery — Jupyter notebook |
| 4 | Schema design — DDL for all 9 tables |
| 5 | Extract layer — API client with retry |
| 6 | Transform layer — flatten, explode, clean |
| 7 | Load layer — SCD2 dimensions + fact append |
| 8 | Pipeline runner — full orchestration |
| 9 | Tests — 43 unit and integration tests |
| 10 | CI/CD — GitHub Actions |
| 11 | Airflow DAG — daily schedule |
| 12 | Docker — containerised deployment |

---

## Author

Phil Dinh