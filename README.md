# Retail ETL Pipeline

End-to-end data pipeline — Python, PostgreSQL, Airflow, Docker, GitHub Actions.

## Stack
- **Extract**: FakeStore API (products, carts, users)
- **Transform**: pandas
- **Load**: PostgreSQL — Full Load + SCD Type 2
- **Orchestrate**: Apache Airflow
- **Containerise**: Docker + Docker Compose
- **CI/CD**: GitHub Actions

## Environments
| Environment | Database | Purpose |
|---|---|---|
| dev | retail_etl_dev | Local development |
| test | retail_etl_test | Automated testing |
| prod | retail_etl_prod | Production runs |

## Setup
1. Clone repo
2. `cp .env.example .env.dev` and fill in credentials
3. `python -m venv venv && venv\Scripts\activate`
4. `pip install -r requirements.txt`


