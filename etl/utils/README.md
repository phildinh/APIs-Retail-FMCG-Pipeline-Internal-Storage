# etl/utils/ — Pipeline Utilities

This folder contains the three foundation modules that every stage
of the pipeline depends on. These are always imported first before
any business logic runs.

---

## Why This Folder Exists

Every pipeline stage (extract, transform, load) needs to:
- Know WHICH database to connect to (config.py)
- Know HOW to connect safely and efficiently (db.py)
- Know HOW to record what happened (logger.py)

Instead of repeating this logic in every file, we write it once
here and import it everywhere. This follows the DRY principle:
Don't Repeat Yourself.

---

## File Overview

    utils/
    ├── config.py   → reads credentials from .env files
    ├── db.py       → manages database connections
    └── logger.py   → sets up structured logging

---

## config.py — Environment Configuration

### What it does

Reads the ENV variable from your operating system, finds the
matching .env file, validates all values, and exposes them as
a typed Python object.

### How it decides which .env file to load

    OS environment variable: ENV=dev
            ↓
    config.py reads it
            ↓
    loads .env.dev  → retail_etl_dev database
    loads .env.test → retail_etl_test database
    loads .env.prod → retail_etl_prod database

    Default: if ENV is not set → loads .env.dev (safe fallback)

### Key concept — why not hardcode credentials?

    Hardcoded:  password = "2011"  → visible on GitHub forever ❌
    .env file:  password read from file → never committed to git ✅

### How to use it

    from etl.utils.config import settings

    print(settings.env)          # "dev"
    print(settings.db_name)      # "retail_etl_dev"
    print(settings.db_url_safe)  # "postgresql+psycopg2://etl_user:***@..."

    # NEVER log settings.db_url  (contains real password)
    # ALWAYS log settings.db_url_safe (password masked)

### Key concept — singleton pattern

`settings = Settings()` runs ONCE when Python first imports this file.
Every other file that imports `settings` gets the SAME object.
The .env file is only read once, not on every import.

### Key concept — pydantic validation

    .env file stores everything as strings:
    DB_PORT=5432 → string "5432"

    Pydantic sees db_port: int
    → converts "5432" to integer 5432 automatically

    If DB_PORT is missing entirely:
    → raises clear error AT STARTUP
    → not deep inside the pipeline when it's hard to debug

---

## db.py — Database Connection Management

### What it does

Creates a pool of reusable database connections and provides
safe context managers to use them.

### Key concept — why connection pooling?

    Without pool:
    Every query → open connection (100ms) → run query (1ms) → close
    1000 queries = 100 seconds wasted just on connecting ❌

    With pool (size=5):
    Startup → open 5 connections once
    1000 queries → reuse same 5 connections
    Total connection cost = ~500ms ✅

### Pool settings and why

    pool_size=5        # 5 permanent connections always open
    max_overflow=10    # up to 10 extra under heavy load (max 15 total)
    pool_timeout=30    # wait max 30 seconds for free connection
    pool_pre_ping=True # test connection before use (handles DB restarts)

### Key concept — context manager (with statement)

    # What you write:
    with get_db_connection() as conn:
        conn.execute(text("INSERT INTO products ..."))
        conn.execute(text("UPDATE staging ..."))

    # What Python guarantees:
    # SUCCESS → both execute → commit → connection returned to pool
    # FAILURE → exception → rollback (undo everything) → connection returned
    # Connection is ALWAYS returned to pool, even if code crashes

### Why rollback matters

    Two queries run inside one "with" block:
    Query 1: INSERT products → succeeds
    Query 2: UPDATE staging  → crashes

    Without rollback: Query 1 is saved, Query 2 not → inconsistent data ❌
    With rollback:    Both undone → database stays clean ✅

### Two types of connections

    get_db_connection()  → SQLAlchemy connection
                           uses connection pool
                           use for: regular queries, small inserts

    get_raw_connection() → direct psycopg2 connection
                           bypasses SQLAlchemy layer
                           use for: bulk COPY operations (100k+ rows)
                           why: PostgreSQL COPY needs raw psycopg2

### Health check

    # Always call this at the start of a pipeline run
    # Fail fast — better to know immediately than to fail mid-pipeline
    from etl.utils.db import test_connection

    if not test_connection():
        # stop pipeline before any work is done
        sys.exit(1)

### How to use it

    from etl.utils.db import get_db_connection, get_raw_connection
    from sqlalchemy import text

    # Regular query
    with get_db_connection() as conn:
        result = conn.execute(text("SELECT * FROM staging.products"))
        rows = result.fetchall()

    # Bulk operation
    with get_raw_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("COPY staging.products FROM STDIN ...")

---

## logger.py — Structured Logging

### What it does

Sets up one root logger with two outputs: terminal (real-time)
and log file (persistent history). Every module gets its own
named logger showing exactly which file the message came from.

### Why not just use print()?

    print("Error!")
    → no timestamp (when did it happen?)
    → no severity (how bad is it?)
    → no source (which file?)
    → disappears when terminal closes

    logger.error("DB connection failed after 3 retries")
    → 2026-03-12 02:13:45 | ERROR | etl.load.full_loader | DB connection failed
    → timestamp ✅  severity ✅  source file ✅  saved to file ✅

### Log levels — when to use each

    logger.debug("Connection acquired from pool")
    → detailed technical info
    → only visible in dev/test environments
    → use for: internal state, query details, step-by-step flow

    logger.info("Loaded 1500 products successfully")
    → normal business events worth recording
    → visible in all environments
    → use for: pipeline milestones, row counts, start/end

    logger.warning("API rate limit approaching, slowing requests")
    → unexpected but pipeline continues
    → visible in all environments
    → use for: retries, slow responses, approaching limits

    logger.error("Failed to insert products: unique constraint violation")
    → something failed, needs attention
    → visible in all environments
    → use for: caught exceptions, failed operations

    logger.critical("Cannot connect to database — stopping pipeline")
    → pipeline completely broken
    → visible in all environments
    → use for: unrecoverable failures

### Log levels per environment

    dev  → DEBUG (see everything, helps during development)
    test → DEBUG (see everything, helps debug failing tests)
    prod → INFO  (meaningful events only, reduce noise)

### Two outputs

    Console (terminal)         → see logs in real time while developing
    File (logs/retail_etl.log) → persistent history for later review

### How to use it in any file

    from etl.utils.logger import get_logger

    # Always pass __name__ — becomes the module path automatically
    # etl/load/full_loader.py → __name__ = "etl.load.full_loader"
    logger = get_logger(__name__)

    # Then use anywhere in the file:
    logger.info("Starting product load")
    logger.debug(f"Processing {len(rows)} rows")
    logger.error(f"Insert failed: {e}")

### Why __name__?

    etl/utils/db.py         → logger name = "etl.utils.db"
    etl/load/full_loader.py → logger name = "etl.load.full_loader"

    Log output:
    2026-03-12 | ERROR | etl.load.full_loader | Insert failed
                         ^^^^^^^^^^^^^^^^^^^^
                         you know EXACTLY which file to open and debug

---

## The Import Order — Always Follow This

    # Standard library first
    import os
    import sys

    # Third party libraries second
    from sqlalchemy import text

    # Our utils always last, in this order
    from etl.utils.config import settings          # 1. config first
    from etl.utils.db import get_db_connection     # 2. db second
    from etl.utils.logger import get_logger        # 3. logger third

    # Then get your logger for this file
    logger = get_logger(__name__)

---

## Common Mistakes To Avoid

    # NEVER log the real database URL
    logger.info(f"Connecting to {settings.db_url}")      # exposes password ❌

    # ALWAYS use the safe version
    logger.info(f"Connecting to {settings.db_url_safe}") # password masked ✅

    # NEVER open a connection without context manager
    conn = engine.connect()
    conn.execute(...)  # if this crashes, connection leaks forever ❌

    # ALWAYS use context manager
    with get_db_connection() as conn:
        conn.execute(...)  # guaranteed cleanup no matter what ✅

    # NEVER call setup_logger() manually in your files
    setup_logger()  # causes duplicate log messages ❌

    # setup_logger() is called once inside config.py automatically
    # Just import settings and logging is ready
    from etl.utils.config import settings  # logger already set up ✅

---

## Quick Reference

| I need to...                  | Use this                                |
|-------------------------------|-----------------------------------------|
| Get a config value            | `from etl.utils.config import settings` |
| Connect to DB safely          | `with get_db_connection() as conn:`     |
| Bulk load data                | `with get_raw_connection() as conn:`    |
| Check DB is reachable         | `test_connection()`                     |
| Log a message in any file     | `logger = get_logger(__name__)`         |
| See which DB I'm connected to | `settings.db_url_safe`                  |
| Know which environment I'm in | `settings.env`                          |

---

*Last updated: Stage 2 — DB Connection Utility*
*Next: Stage 3 — Database Schema Design (sql/ddl/)*