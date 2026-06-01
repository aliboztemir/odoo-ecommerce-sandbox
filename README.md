# odoo-ecommerce-sandbox

A Docker Compose environment for spinning up a local Odoo instance with the e-commerce module enabled. Used as the test target for end-to-end and UI automation suites.

---

## What it does

Starts three containers:

- **db** — PostgreSQL 15 database
- **odoo** — Odoo 19.0 with e-commerce, sales, payment, stock, and portal modules installed
- **odoo-init** — one-shot init container that configures the environment for testing

The init container runs automatically after Odoo is healthy and prepares:

- Demo payment provider set to test mode
- EUR as the active company currency
- At least one published product available in the shop
- Automatic invoicing enabled
- A portal customer account ready for checkout flows

---

## Requirements

- Docker
- Docker Compose

---

## How to start

```sh
docker compose up -d
```

Odoo will be available at `http://localhost:8069` once the health check passes. The init container runs once and exits. Check its logs to confirm setup completed:

```sh
docker logs odoo_init
```

---

## Access

| Role | URL | Credentials |
|------|-----|-------------|
| Admin | http://localhost:8069/web | admin / admin |
| Shop | http://localhost:8069/shop | — |
| Portal customer | http://localhost:8069/shop | customer@example.com / customer123 |

---

## Configuration

Odoo options are defined in `config/odoo.conf`. Database connection and module list are set in `docker-compose.yml`.

---

## Stopping

```sh
docker compose down
```

To also remove volumes (full reset):

```sh
docker compose down -v
```