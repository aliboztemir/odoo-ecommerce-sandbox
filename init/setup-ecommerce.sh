#!/bin/bash
set -euo pipefail

ODOO_URL="${ODOO_URL:-http://odoo:8069}"
ODOO_DB="${ODOO_DB:-odoo}"
ODOO_ADMIN_USER="${ODOO_ADMIN_USER:-admin}"
ODOO_ADMIN_PASSWORD="${ODOO_ADMIN_PASSWORD:-admin}"
TEST_CUSTOMER_EMAIL="${TEST_CUSTOMER_EMAIL:-customer@example.com}"
TEST_CUSTOMER_PASSWORD="${TEST_CUSTOMER_PASSWORD:-customer123}"

echo "[setup] Waiting for Odoo at ${ODOO_URL}/web/health ..."
until curl -sf "${ODOO_URL}/web/health" > /dev/null 2>&1; do
  sleep 5
done
echo "[setup] Odoo is ready."

python3 <<'PYEOF'
import os, sys, xmlrpc.client, psycopg2

url               = os.environ['ODOO_URL']
db                = os.environ['ODOO_DB']
admin_user        = os.environ['ODOO_ADMIN_USER']
admin_password    = os.environ['ODOO_ADMIN_PASSWORD']
customer_email    = os.environ['TEST_CUSTOMER_EMAIL']
customer_password = os.environ['TEST_CUSTOMER_PASSWORD']

common = xmlrpc.client.ServerProxy(f'{url}/xmlrpc/2/common')
uid = common.authenticate(db, admin_user, admin_password, {})
if not uid:
    print('[ERROR] Authentication failed', file=sys.stderr)
    sys.exit(1)
m = xmlrpc.client.ServerProxy(f'{url}/xmlrpc/2/object')

# ── DB connection (used for EUR + portal group) ───────────────────────────────
pg = psycopg2.connect(
    host=os.environ.get('HOST', 'db'),
    port=os.environ.get('PORT', '5432'),
    dbname=db,
    user=os.environ.get('USER', 'odoo'),
    password=os.environ.get('PASSWORD', 'odoo_password'),
)
cur = pg.cursor()

# ── 1. Demo Payment Provider ──────────────────────────────────────────────────
providers = m.execute_kw(db, uid, admin_password,
    'payment.provider', 'search', [[['code', '=', 'demo']]], {})
if not providers:
    print('[ERROR] Demo payment provider not found.', file=sys.stderr)
    sys.exit(1)
m.execute_kw(db, uid, admin_password,
    'payment.provider', 'write', [providers, {'state': 'test', 'is_published': True}])
print(f'[setup] Demo provider configured: ids={providers}')

# ── 2. Activate EUR and set as company currency ───────────────────────────────
cur.execute("UPDATE res_currency SET active = true WHERE name = 'EUR' RETURNING id")
eur_row = cur.fetchone()
if eur_row:
    cur.execute("UPDATE res_company SET currency_id = %s", (eur_row[0],))
    print(f'[setup] EUR activated and set as company currency (id={eur_row[0]}).')
else:
    print('[WARN] EUR not found in DB.', file=sys.stderr)

# ── 3. Find a published product, publish one if needed ───────────────────────
products = m.execute_kw(db, uid, admin_password,
    'product.template', 'search_read',
    [[['sale_ok', '=', True], ['list_price', '>', 0], ['is_published', '=', True]]],
    {'fields': ['name', 'list_price'], 'limit': 1})

if not products:
    products = m.execute_kw(db, uid, admin_password,
        'product.template', 'search_read',
        [[['sale_ok', '=', True], ['list_price', '>', 0]]],
        {'fields': ['name', 'list_price'], 'limit': 1})
    if not products:
        print('[ERROR] No usable product found. Ensure demo data is loaded.', file=sys.stderr)
        sys.exit(1)
    m.execute_kw(db, uid, admin_password,
        'product.template', 'write', [[products[0]['id']], {'is_published': True}])
    print(f'[setup] Published product: id={products[0]["id"]}, name={products[0]["name"]}')

usable_product = products[0]
m.execute_kw(db, uid, admin_password,
    'product.template', 'write', [[usable_product['id']], {'invoice_policy': 'order'}])
print(f'[setup] Usable product: id={usable_product["id"]}, name={usable_product["name"]}, price={usable_product["list_price"]}')

# ── 4. Automatic invoicing ────────────────────────────────────────────────────
existing_param = m.execute_kw(db, uid, admin_password,
    'ir.config_parameter', 'search', [[['key', '=', 'sale.automatic_invoice']]], {})
if existing_param:
    m.execute_kw(db, uid, admin_password,
        'ir.config_parameter', 'write', [existing_param, {'value': 'True'}])
else:
    m.execute_kw(db, uid, admin_password,
        'ir.config_parameter', 'create', [{'key': 'sale.automatic_invoice', 'value': 'True'}])
print('[setup] sale.automatic_invoice = True')

# ── 5. Create or update portal customer ──────────────────────────────────────
existing_user = m.execute_kw(db, uid, admin_password,
    'res.users', 'search', [[['login', '=', customer_email]]], {})

if existing_user:
    m.execute_kw(db, uid, admin_password,
        'res.users', 'write', [existing_user, {'active': True, 'password': customer_password}])
    portal_user_id = existing_user[0]
    print(f'[setup] Portal customer updated: id={portal_user_id}')
else:
    portal_user_id = m.execute_kw(db, uid, admin_password,
        'res.users', 'create', [{
            'name':     customer_email.split('@')[0].capitalize(),
            'login':    customer_email,
            'email':    customer_email,
            'password': customer_password,
            'active':   True,
        }])
    print(f'[setup] Portal customer created: id={portal_user_id}')

user_info = m.execute_kw(db, uid, admin_password,
    'res.users', 'read', [[portal_user_id]], {'fields': ['partner_id']})
partner_id = user_info[0]['partner_id'][0]

cur.execute("SELECT res_id FROM ir_model_data WHERE module='base' AND name='group_portal'")
portal_gid = cur.fetchone()[0]
cur.execute("SELECT id FROM res_users WHERE login=%s", (customer_email,))
uid_portal = cur.fetchone()[0]
cur.execute("INSERT INTO res_groups_users_rel (gid, uid) VALUES (%s, %s) ON CONFLICT DO NOTHING", (portal_gid, uid_portal))
cur.execute("SELECT res_id FROM ir_model_data WHERE module='base' AND name IN ('group_user', 'group_public')")
other_gids = [r[0] for r in cur.fetchall()]
if other_gids:
    cur.execute("DELETE FROM res_groups_users_rel WHERE uid=%s AND gid=ANY(%s)", (uid_portal, other_gids))

m.execute_kw(db, uid, admin_password,
    'res.partner', 'write', [[partner_id], {'email': customer_email, 'customer_rank': 1, 'active': True}])

pg.commit()
cur.close()
pg.close()
print(f'[setup] Portal user ready: id={portal_user_id}, login={customer_email}, partner_id={partner_id}')

# ── Summary ───────────────────────────────────────────────────────────────────
print('')
print('=' * 60)
print('[setup] SETUP COMPLETE')
print('=' * 60)
print(f'  Odoo URL      : {url}')
print(f'  Shop URL      : {url}/shop')
print(f'  Demo provider : ids={providers}, state=test')
print(f'  Currency      : EUR')
print(f'  Auto invoice  : sale.automatic_invoice=True')
print(f'  Product       : id={usable_product["id"]}, name={usable_product["name"]}')
print(f'  Portal user   : id={portal_user_id}, login={customer_email}')
print('=' * 60)
PYEOF