# tests/ — Test Suite

43 automated tests covering the full ETL pipeline.

---

## Structure
```
tests/
├── unit/
│   ├── test_products_transform.py  → 9 tests
│   ├── test_carts_transform.py     → 13 tests
│   └── test_users_transform.py     → 17 tests
└── integration/
    └── test_pipeline_integration.py → 4 tests
```

---

## Running Tests

**Unit tests (no database needed):**
```powershell
pytest tests/unit/ -v
```

**Integration tests (requires retail_etl_test database):**
```powershell
$env:ENV="test"; pytest tests/integration/ -v
```

**All tests:**
```powershell
pytest tests/unit/ -v
$env:ENV="test"; pytest tests/integration/ -v
```

---

## Unit Tests

No database. No API. Test one function at a time with fake data.
Fast — runs in under 1 second.

### test_products_transform.py (9 tests)
- source_id renamed correctly from id
- rating.rate and rating.count flattened
- price cast to float
- image renamed to image_url
- missing rating handled gracefully (returns None)
- output has exactly the right keys

### test_carts_transform.py (13 tests)
- date string parsed to Python date object
- 1 cart + 1 product → 1 row
- 1 cart + 3 products → 3 rows (explode logic)
- empty products list → empty list, no crash
- all exploded rows carry correct cart_source_id
- all exploded rows carry correct user_source_id
- product ids and quantities match correctly

### test_users_transform.py (17 tests)
- password NEVER in output (most critical test)
- password value not stored under any key
- name.firstname → first_name
- name.lastname → last_name
- address fields all flattened correctly
- lat/lng cast from string to float
- bad geolocation → None, no crash
- missing address → all address fields None

---

## Integration Tests

Uses real `retail_etl_test` database.
Tests full read → transform → write cycle end to end.

**Requires:**
- PostgreSQL running locally
- `retail_etl_test` database with schemas created:
```powershell
psql -U etl_user -d retail_etl_test -f sql/ddl/create_schemas.sql
psql -U etl_user -d retail_etl_test -f sql/ddl/create_tables.sql
```

### test_pipeline_integration.py (4 tests)
- Products: insert raw → transform → verify staging rows
- Carts: 1 cart with 3 products → 3 staging rows
- Users: password never reaches staging database
- Products rerun: truncate prevents duplicate rows

---

## CI/CD

Unit tests run automatically on every push via GitHub Actions.
See `.github/workflows/ci.yml`.
```
Push code → GitHub Actions → 39 unit tests → green or red
```

Integration tests run locally only (require database).

---

## Key Testing Concepts Used
```
Fixtures    → fake data defined once, reused across tests
autouse     → fixture runs automatically for every test
ARRANGE     → set up fake inputs
ACT         → call the function
ASSERT      → verify the output
Teardown    → clean database after each integration test
Skip guard  → integration tests skip if ENV != test
```

---

*Last updated: Stage 9 — Tests*