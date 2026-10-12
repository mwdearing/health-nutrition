#!/usr/bin/env python3
"""Real RPC boundary checks: many individually valid alternatives, bounded reads and recovery."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import uuid

engine, container = sys.argv[1:]
base = [engine, 'exec', '-i', container, 'psql', '-X', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq']
def sql(q):
    r = subprocess.run(base, input=q, text=True, capture_output=True, timeout=180)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()
def lit(x): return "'" + x.replace("'", "''") + "'"
def js(x): return lit(json.dumps(x, ensure_ascii=False)) + '::jsonb'
def identity(a): return f"set role authenticated; set request.jwt.claim.sub={lit(a)}; set request.jwt.claims='{{\"is_anonymous\":false}}';"
def rpc(a, name, arg=''):
    raw = sql(identity(a) + f'select public.{name}({arg});')
    return json.loads(raw), len(raw.encode())
def error(a, name, arg, code):
    sql(identity(a) + f"""do $t$ declare d text; begin begin
    perform public.{name}({arg}); raise exception 'unexpected success' using errcode='XX000';
    exception when sqlstate 'P0001' then get stacked diagnostics d=pg_exception_detail;
    assert d::jsonb->>'code'={lit(code)}; end; end $t$;""")
fixture = json.loads(Path('contracts/catalog-api/fixtures/shared-products-v2/exact-16384-valid.json').read_text())
accounts = [str(uuid.uuid4()) for _ in range(67)]
sql('insert into auth.users(id) values ' + ','.join('('+lit(a)+')' for a in accounts) + ';')
for a in accounts: rpc(a, 'acknowledge_catalog_consent_v2', '2')
def request(i, pid=None, revision=None):
    body = copy.deepcopy(fixture)
    body.update(operation_id=str(uuid.uuid4()), client_revision_id=str(uuid.uuid4()), product_id=pid,
                expected_server_revision=revision)
    body['product']['facts'][0]['key'] = 'ingredient:x' + str(i).zfill(52)
    body['product']['facts'][0]['display_name'] = 'Synthetic fact'
    return body
created = []
for product_number in range(4):
    first = request(0)
    first['product']['name'] = 'Synthetic bounded ' + str(product_number)
    receipt, _ = rpc(accounts[0], 'submit_catalog_product_v2', js(first))
    pid = receipt['product_id']
    statements = []
    for i, a in enumerate(accounts[1:], 1):
        body = request(i, pid)
        body['product']['name'] = first['product']['name']
        statements.append(identity(a) + 'do $t$ begin perform public.submit_catalog_product_v2(' + js(body) + '); end $t$; reset role;')
    sql('\n'.join(statements))
    created.append((pid, first, receipt))

pid, original, accepted = created[0]
detail, size = rpc(accounts[0], 'get_catalog_product_v2', lit(pid))
assert size <= 262144, f'bounded detail required: {size} bytes'
pub = detail['product']
assert pub['alternatives_total'] == '66' and pub['alternatives_cursor'] is not None
seen = [a['representative_revision'] for a in pub['alternatives']]
cursor = pub['alternatives_cursor']
first_cursor = cursor
while cursor:
    page, size = rpc(accounts[0], 'get_catalog_product_alternatives_v2', f'{lit(pid)},{lit(cursor)},20')
    assert size <= 262144 and page['alternatives_total'] == '66' and len(page['alternatives']) <= 20
    seen += [a['representative_revision'] for a in page['alternatives']]
    cursor = page['next_cursor']
assert len(seen) == len(set(seen)) == 66
assert all(a not in json.dumps(pub) for a in accounts)
page, size = rpc(accounts[0], 'search_catalog_products_v2', "'Synthetic bounded',null,null,20")
assert size <= 786432 and page['next_cursor'] is not None
all_ids = [p['product_id'] for p in page['products']]
while page['next_cursor']:
    page, size = rpc(accounts[0], 'search_catalog_products_v2', "'Synthetic bounded',null,"+lit(page['next_cursor'])+",20")
    assert size <= 786432
    all_ids += [p['product_id'] for p in page['products']]
assert set(all_ids) == {p[0] for p in created} and len(all_ids) == 4
replay, size = rpc(accounts[0], 'submit_catalog_product_v2', js(original))
assert size <= 262144 and replay['replayed'] and replay['acknowledged_revision'] == accepted['acknowledged_revision']
resolved, size = rpc(accounts[0], 'resolve_catalog_publish_for_withdrawal_v2', js(original))
assert size <= 262144 and resolved['receipt'] == replay
withdraw = dict(operation_id=str(uuid.uuid4()), client_revision_id=str(uuid.uuid4()), product_id=pid,
                expected_server_revision=replay['current_revision'])
removed, size = rpc(accounts[0], 'withdraw_catalog_product_v2', js(withdraw))
assert size <= 262144 and removed['current_state'] == 'withdrawn'
error(accounts[0], 'get_catalog_product_alternatives_v2', f'{lit(pid)},{lit(first_cursor)},20', 'revision_conflict')
resolved, size = rpc(accounts[0], 'resolve_catalog_publish_for_withdrawal_v2', js(original))
assert size <= 262144 and resolved['receipt']['current_state'] == 'withdrawn'
republication = request(99, pid, removed['current_revision'])
republished, size = rpc(accounts[0], 'submit_catalog_product_v2', js(republication))
assert size <= 262144 and republished['current_state'] == 'active'
replayed_withdraw, size = rpc(accounts[0], 'withdraw_catalog_product_v2', js(withdraw))
assert size <= 262144 and replayed_withdraw['current_state'] == 'active'
caps, _ = rpc(accounts[0], 'catalog_capabilities_v2')
assert caps['bounded_publication_version'] == 1
print('BOUNDED PUBLICATION OK: 67 valid contributions x 4 identities; paging/search/replay/withdraw/resolution')
