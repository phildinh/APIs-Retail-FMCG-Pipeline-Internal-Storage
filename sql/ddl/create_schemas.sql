-- sql/ddl/create_schemas.sql
-- ═══════════════════════════════════════════════════════════
-- PURPOSE: Create the three schemas for medallion architecture
--
-- Run this ONCE before creating any tables
-- Safe to re-run (IF NOT EXISTS prevents errors)
--
-- WHY THREE SCHEMAS INSTEAD OF ONE?
-- Schema = a namespace (like a folder) inside PostgreSQL
--
-- Without schemas, all tables live in "public":
--   public.products_raw
--   public.products_staging
--   public.dim_products
--   hard to manage, hard to set permissions ❌
--
-- With schemas:
--   raw.products       → clearly Bronze layer
--   staging.products   → clearly Silver layer
--   warehouse.products → clearly Gold layer
--   clean, organised, permission-friendly ✅
--
-- PERMISSION BENEFIT (real world):
--   GRANT USAGE ON SCHEMA raw TO etl_user
--   GRANT USAGE ON SCHEMA warehouse TO analyst_user
--   Analysts can only read warehouse, never touch raw ✅
-- ═══════════════════════════════════════════════════════════

-- Bronze: exact API responses, never modified
CREATE SCHEMA IF NOT EXISTS raw;

-- Silver: cleaned, typed, flat data
CREATE SCHEMA IF NOT EXISTS staging;

-- Gold: business-ready, history preserved
CREATE SCHEMA IF NOT EXISTS warehouse;