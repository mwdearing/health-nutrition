#!/usr/bin/env python3
"""Synthetic fixtures, adversarial behavior and real blocked-session races on run.sh's database."""
import json
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

ENGINE, CONTAINER = sys.argv[1:]
BASE = [ENGINE, 'exec', '-i', CONTAINER, 'psql', '-X', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq']
FIXTURES = Path('contracts/catalog-api/fixtures/shared-products-v2')

def literal(value):
    return "'" + value.replace("'", "''") + "'"

def jsql(value):
    return literal(json.dumps(value, ensure_ascii=False)) + '::jsonb'

def sql(query):
    result = subprocess.run(BASE, input=query, text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout.strip()

def identity(account):
    return f"set role authenticated; set request.jwt.claim.sub={literal(account)}; set request.jwt.claims='{{\"is_anonymous\":false}}';"

def rpc(account, name, arg=''):
    return json.loads(sql(identity(account) + f'select public.{name}({arg});'))

def expect_error(account, name, arg, code):
    # Inspect machine-readable DETAIL, not merely an exception of any kind.
    query = f"""do $test$ declare d text; begin
      begin perform public.{name}({arg}); raise exception 'unexpected success' using errcode='XX000';
      exception when sqlstate 'P0001' then get stacked diagnostics d=pg_exception_detail;
      assert d::jsonb->>'code'={literal(code)}; end;
    end $test$;"""
    sql(identity(account) + query)

def product(name='Synthetic race product', barcode=None):
    return dict(name=name, brand=None, barcode=barcode, kind='food', basis='per_100_g', serving=None,
                facts=[dict(key='protein', display_name='Protein', state='known', amount='1', unit='g')])

def request(content=None, pid=None, expected=None, generation='0'):
    return dict(operation_id=str(uuid.uuid4()), client_revision_id=str(uuid.uuid4()), product_id=pid,
                expected_server_revision=expected, consent_version=2, consent_generation=generation,
                product=content or product())

def submit(a, body):
    return rpc(a, 'submit_catalog_product_v2', jsql(body))

def account():
    a = str(uuid.uuid4())
    sql(f'insert into auth.users(id) values({literal(a)});')
    rpc(a, 'acknowledge_catalog_consent_v2', '2')
    return a

class Session:
    def __init__(self, name, a=None):
        self.name = name
        self.p = subprocess.Popen(BASE, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, bufsize=1)
        self.lines = []
        self.thread = threading.Thread(target=lambda: self.lines.extend(self.p.stdout), daemon=True)
        self.thread.start()
        self.send(f'set application_name={literal(name)}; set statement_timeout=15000;' + (identity(a) if a else ''))
    def send(self, query):
        self.p.stdin.write(query + '\n'); self.p.stdin.flush()
    def marker(self, marker):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if any(line.strip() == marker for line in self.lines):
                return
            if self.p.poll() is not None:
                raise AssertionError(self.p.stderr.read())
            time.sleep(.03)
        raise AssertionError('session barrier timeout: ' + self.name)
    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=20); self.thread.join(timeout=2)
        assert self.p.returncode == 0, self.p.stderr.read()
        return [json.loads(line) for line in self.lines if line.startswith('{')]

def blocked(session):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        count = sql(f"select count(*) from pg_stat_activity where application_name={literal(session.name)} and wait_event_type='Lock';")
        if count == '1':
            return
        time.sleep(.05)
    raise AssertionError('second database session never reached lock barrier')

def serialize(first_sql, second_sql, a, b):
    first = Session('v2-first-' + uuid.uuid4().hex, a)
    second = Session('v2-second-' + uuid.uuid4().hex, b)
    first.send("begin; " + first_sql + "; select 'FIRST_HELD';")
    first.marker('FIRST_HELD')
    second.send(second_sql + "; select 'SECOND_FINISHED';")
    blocked(second)  # Demonstrates overlapping transactions, not sequential calls labelled as a race.
    first.send('commit;'); first_result = first.close()
    second.marker('SECOND_FINISHED'); second_result = second.close()
    return first_result, second_result

def main():
    sql('update catalog.settings set daily_limit=1000,min_devices=2;')
    a, b = account(), account()
    # Execute canonical fixtures in PostgreSQL, using the frozen cross-platform byte corpus.
    for filename, length in [('exact-16384-valid.json', 16384), ('oversize-16385-invalid.json', 16385)]:
        raw = json.loads((FIXTURES / filename).read_text())
        assert int(sql(f'select octet_length(catalog_v2.canonical({jsql(raw)}));')) == length
    renderer = json.loads((FIXTURES / 'renderer-sql-input.json').read_text())
    expected = (FIXTURES / 'renderer-sql-expected.json').read_text().rstrip('\n')
    assert sql(f'select catalog_v2.canonical({jsql(renderer)});') == expected
    abstract = json.loads((FIXTURES / 'renderer-input.json').read_text())
    # The actual jsonb decoder (pre-RPC) fails with 22P05, not our application error.
    sql(f"""do $test$ begin begin perform {jsql(abstract)}; raise exception 'NUL accepted';
        exception when sqlstate '22P05' then null; end; end $test$;""")
    for vector in json.loads((FIXTURES / 'unicode-normalization-vectors.json').read_text())['search']:
        assert sql(f'select catalog_v2.search_name({literal(vector["input"])});') == vector['normalized']
    for filename in ['name-only-valid.json','fact-states-valid.json','unicode-120-valid.json',
                     'barcode-valid.json','amount-max-valid.json','key-identity-valid.json']:
        body = json.loads((FIXTURES / filename).read_text())
        body['operation_id'] = str(uuid.uuid4())
        submit(a, body)
    for filename in ['nested-private-invalid.json','serving-private-invalid.json','unicode-121-invalid.json',
                     'barcode-checksum-invalid.json','amount-over-max-invalid.json','dimension-invalid.json',
                     'unknown-standard-invalid.json','threshold-amount-invalid.json','key-duplicate-invalid.json']:
        body = json.loads((FIXTURES / filename).read_text())
        body['operation_id'] = str(uuid.uuid4())
        expect_error(a,'submit_catalog_product_v2',jsql(body),'invalid_request')
    exact = json.loads((FIXTURES / 'exact-16384-valid.json').read_text())
    exact['operation_id'] = str(uuid.uuid4())
    submit(a, exact)
    over = json.loads((FIXTURES / 'oversize-16385-invalid.json').read_text())
    expect_error(a,'submit_catalog_product_v2',jsql(over),'invalid_request')

    # Every public object and nested object has an allowlist; mutation tests exercise each layer.
    body = request()
    mutations = [dict(body, notes='private'), dict(body, operation_id=None), dict(body, client_revision_id=2),
                 dict(body, operation_id=uuid.uuid4().hex), dict(body, consent_version='2'), dict(body, expected_server_revision='0')]
    for path in [('product',), ('product','facts',0)]:
        changed = json.loads(json.dumps(body)); target = changed
        for component in path: target = target[component]
        target['notes'] = 'private'; mutations.append(changed)
    for changed in mutations: expect_error(a,'submit_catalog_product_v2',jsql(changed),'invalid_request')

    # Deep unexpected nesting must produce a typed validation error, not exhaust the SQL stack.
    nested = '0'
    for _ in range(2000): nested = '{"x":'+nested+'}'
    sql(identity(a)+f"""do $test$ declare d text; begin begin
      perform public.submit_catalog_product_v2({literal(nested)}::jsonb);
      raise exception 'deep object accepted' using errcode='XX000';
      exception when sqlstate 'P0001' then get stacked diagnostics d=pg_exception_detail;
      assert d::jsonb->>'code'='invalid_request'; end; end $test$;""")

    # Exact decimal factors across every supported dimension, without binary rounding.
    for first_unit, first_amount, second_unit, second_amount, equal in [
        ('oz','8000','g','226796.185',True), ('kg','1','mcg','1000000000',True),
        ('L','1','mL','1000',True), ('fl oz','16','cup','2',True),
        ('tbsp','1','tsp','3',True), ('capsule','1','tablet','1',False),
        ('IU','1','mcg','1',False), ('kcal','1','g','1',False)]:
        x=product();y=product()
        x['facts'][0].update(key='ingredient:synthetic',unit=first_unit,amount=first_amount)
        y['facts'][0].update(key='ingredient:synthetic',unit=second_unit,amount=second_amount)
        assert sql(f'select catalog_v2.equivalence({jsql(x)})=catalog_v2.equivalence({jsql(y)});') == ('t' if equal else 'f')
    # Canonical uppercase UUIDs are valid; aliases and changed body spelling are not identical retries.
    uppercase=request();uppercase['operation_id']=uppercase['operation_id'].upper();uppercase['client_revision_id']=uppercase['client_revision_id'].upper()
    ack=submit(a,uppercase)
    assert ack['operation_id']==str(uuid.UUID(uppercase['operation_id']))
    expect_error(a,'submit_catalog_product_v2',jsql(dict(uppercase,operation_id=uppercase['operation_id'].lower())),'operation_conflict')
    # Numeric serving defines agreement; human serving text stays on the actual representative.
    x=product('Synthetic serving agreement');x.update(basis='per_serving',serving=dict(quantity='1',unit='capsule',text='First display'))
    first=submit(a,request(x));y=json.loads(json.dumps(x));y['serving']['text']='Other display'
    second=submit(b,request(y,first['product_id']))
    assert second['publication']['support']['distinct_accounts']=='2'
    assert second['publication']['product']['serving']['text']=='First display'

    # Actual profile lock race: duplicate lost reply is one revision and one receipt.
    body = request()
    one, two = serialize(f'select public.submit_catalog_product_v2({jsql(body)})',
                         f'select public.submit_catalog_product_v2({jsql(body)})', a, a)
    assert one[0]['product_id'] == two[0]['product_id'] and two[0]['replayed']
    assert one[0]['acknowledged_revision'] == two[0]['acknowledged_revision']
    # Different accounts overlap at the canonical barcode advisory lock.
    upc = request(product(barcode='012345678905'))
    ean = request(product(barcode='0012345678905'))
    one, two = serialize(f'select public.submit_catalog_product_v2({jsql(upc)})',
                         f'select public.submit_catalog_product_v2({jsql(ean)})', a, b)
    assert one[0]['product_id'] == two[0]['product_id']
    pid = one[0]['product_id']
    publication = rpc(a,'get_catalog_product_v2',literal(pid))['product']
    assert publication['support']['distinct_accounts'] == '2'
    assert publication['verification'] == dict(status='shared_unverified',source=None)
    # Exact supported unit equivalence, spelling preserved, one account cannot add votes.
    current = rpc(b,'get_my_catalog_contribution_v2',literal(pid))
    content = product(barcode='0012345678905'); content['facts'][0].update(amount='1000.000000',unit='mg')
    update = request(content,pid,current['current_revision'])
    equivalent = submit(b,update)
    assert equivalent['publication']['support']['distinct_accounts']=='2'
    assert equivalent['publication']['alternatives']==[]
    content['facts'][0]['amount']='2000'
    conflicting = submit(b,request(content,pid,equivalent['current_revision']))
    assert conflicting['publication']['support']['distinct_accounts']=='1'
    assert len(conflicting['publication']['alternatives'])==1
    # Owner reviews the exact immutable representative; no app executable grant.
    rep = conflicting['publication']['representative_revision']
    sql(f'select catalog_v2.moderate({literal(pid)},false,{rep});')
    assert rpc(a,'get_catalog_product_v2',literal(pid))['product']['verification']['status']=='verified'
    sql(f'select catalog_v2.moderate({literal(pid)},true);')
    assert rpc(a,'get_catalog_product_v2',literal(pid))['product'] is None
    expect_error(a,'submit_catalog_product_v2',jsql(request(product(barcode='012345678905'),pid,one[0]['current_revision'])),'rejected')

    own = rpc(a,'get_my_catalog_contribution_v2',literal(pid))
    assert own['current_state']=='rejected' and own['current_revision']==one[0]['current_revision']
    replay = submit(a,upc)
    assert replay['current_state']=='rejected' and replay['acknowledged_revision']==one[0]['acknowledged_revision']
    withdrawal=dict(operation_id=str(uuid.uuid4()),client_revision_id=str(uuid.uuid4()),product_id=pid,expected_server_revision=own['current_revision'])
    removed=rpc(a,'withdraw_catalog_product_v2',jsql(withdrawal))
    assert removed['current_state']=='withdrawn'
    assert submit(a,upc)['current_state']=='withdrawn'
    sql(f'select catalog_v2.moderate({literal(pid)},false);')
    assert rpc(b,'get_catalog_product_v2',literal(pid))['product'] is not None
    assert rpc(a,'get_my_catalog_contribution_v2',literal(pid))['current_state']=='withdrawn'
    # Identity kind persists after all contributions retire; it is never inferred for legacy-only IDs.
    before=rpc(b,'get_my_catalog_contribution_v2',literal(pid))
    withdrawal.update(operation_id=str(uuid.uuid4()),expected_server_revision=before['current_revision'])
    rpc(b,'withdraw_catalog_product_v2',jsql(withdrawal))
    changed=product(barcode='012345678905'); changed['kind']='supplement'
    expect_error(account(),'submit_catalog_product_v2',jsql(request(changed)),'invalid_request')

    # Opt-out holds the profile lock before racing publication; no stale permission acceptance.
    c = account(); body = request()
    query = f"do $test$ declare d text; begin begin perform public.submit_catalog_product_v2({jsql(body)}); raise exception 'accepted'; exception when sqlstate 'P0001' then get stacked diagnostics d=pg_exception_detail; assert d::jsonb->>'code'='consent_required'; end; end $test$"
    serialize('update public.profiles set share_labels=false where id=auth.uid()',query,c,c)
    assert rpc(c,'catalog_capabilities_v2')['consent_generation']=='1'

    # Concurrent CAS: second request observes first's committed revision and fails, never overwrites.
    d = account(); first = submit(d,request()); update1=request(pid=first['product_id'],expected=first['current_revision']); update2=request(pid=first['product_id'],expected=first['current_revision'])
    query=f"do $test$ declare d text; begin begin perform public.submit_catalog_product_v2({jsql(update2)}); raise exception 'accepted'; exception when sqlstate 'P0001' then get stacked diagnostics d=pg_exception_detail; assert d::jsonb->>'code'='revision_conflict'; end; end $test$"
    serialize(f'select public.submit_catalog_product_v2({jsql(update1)})',query,d,d)

    # Withdrawal racing an old publish replay never resurrects the retired contribution.
    racer=account(); old=request(); accepted=submit(racer,old)
    withdrawal=dict(operation_id=str(uuid.uuid4()),client_revision_id=str(uuid.uuid4()),product_id=accepted['product_id'],expected_server_revision=accepted['current_revision'])
    _, replayed=serialize(f'select public.withdraw_catalog_product_v2({jsql(withdrawal)})',
                          f'select public.submit_catalog_product_v2({jsql(old)})',racer,racer)
    assert replayed[0]['current_state']=='withdrawn' and replayed[0]['publication'] is None
    # Disabled writes and stale acknowledgments fail, but receipts and withdrawals remain usable.
    gate=account(); body=request(); ack=submit(gate,body)
    sql('update catalog_v2.settings set enabled=false;')
    expect_error(gate,'submit_catalog_product_v2',jsql(request()),'unavailable')
    assert submit(gate,body)['replayed']
    sql('update catalog_v2.settings set enabled=true;')
    sql(identity(gate)+'update public.profiles set share_labels=false where id=auth.uid(); update public.profiles set share_labels=true where id=auth.uid();')
    expect_error(gate,'submit_catalog_product_v2',jsql(request(generation='1')),'consent_required')
    rpc(gate,'acknowledge_catalog_consent_v2','2')
    submit(gate,request(generation='1'))
    # Server usage is one per new accepted operation; retry and withdrawal never reset the limit.
    limited=account(); sql('update catalog.settings set daily_limit=1;')
    body=request(); ack=submit(limited,body)
    assert submit(limited,body)['replayed']
    expect_error(limited,'submit_catalog_product_v2',jsql(request()),'rate_limited')
    withdrawal=dict(operation_id=str(uuid.uuid4()),client_revision_id=str(uuid.uuid4()),product_id=ack['product_id'],expected_server_revision=ack['current_revision'])
    assert rpc(limited,'withdraw_catalog_product_v2',jsql(withdrawal))['current_state']=='withdrawn'
    expect_error(limited,'submit_catalog_product_v2',jsql(request()),'rate_limited')
    sql('update catalog.settings set daily_limit=1000;')
    # Greatest-support alternative selects real content; unknown-only content cannot be owner verified.
    voters=[account(),account(),account()]
    one=submit(voters[0],request(product('Synthetic support winner')))
    other=product('Synthetic alternate winner');other['facts'][0]['amount']='7'
    two=submit(voters[1],request(other,one['product_id']))
    three=submit(voters[2],request(other,one['product_id']))
    assert three['publication']['representative_revision']==two['current_revision']
    assert three['publication']['support']['distinct_accounts']=='2'
    assert three['publication']['product']['facts'][0]['amount']=='7'
    blank=product('Synthetic incomplete');blank['facts']=[dict(key='protein',display_name='Protein',state='unknown')]
    incomplete=submit(voters[0],request(blank))
    assert incomplete['publication']['missing_facts'] is True
    sql(f"""do $test$ declare d text; begin begin
      perform catalog_v2.moderate({literal(incomplete['product_id'])},false,{incomplete['current_revision']});
      raise exception 'incomplete reviewed' using errcode='XX000';
      exception when sqlstate 'P0001' then get stacked diagnostics d=pg_exception_detail; assert d::jsonb->>'code'='invalid_request'; end; end $test$;""")

    # Stable literal keyset pages, mismatched/malformed cursors, and live moderation after page one.
    e = account(); ids=[]
    for name in ['Synthetic cursor A','Synthetic cursor B','Synthetic cursor C']:
        ids.append(submit(e,request(product(name)))['product_id'])
    page = rpc(e,'search_catalog_products_v2',"'Synthetic cursor',null,null,1")
    assert len(page['products'])==1 and page['next_cursor']
    cursor = page['next_cursor']
    expect_error(e,'search_catalog_products_v2',f"'Different query',null,{literal(cursor)},1",'invalid_request')
    expect_error(e,'search_catalog_products_v2',"'Synthetic',null,'malformed',1",'invalid_request')
    for limit in [0,21]: expect_error(e,'search_catalog_products_v2',f"'Synthetic',null,null,{limit}",'invalid_request')
    sql(f'select catalog_v2.moderate({literal(ids[1])},true);')
    page2=rpc(e,'search_catalog_products_v2',f"'Synthetic cursor',null,{literal(cursor)},1")
    assert [p['product_id'] for p in page2['products']]==[ids[2]]
    assert page2['next_cursor'] is None
    # Compact cursor reconstructs a long NFKC key from its bounded original source.
    expanding = '\ufdfa' * 110
    for suffix in [' A',' B',' C']:
        submit(e,request(product(expanding+suffix)))
    q = 'صلى'
    page=rpc(e,'search_catalog_products_v2',f"{literal(q)},null,null,1")
    assert len(page['next_cursor'].encode())<=1024
    page2=rpc(e,'search_catalog_products_v2',f"{literal(q)},null,{literal(page['next_cursor'])},1")
    assert page2['products'][0]['product_id']!=page['products'][0]['product_id']
    expanded=product('\u0344'*61)
    expect_error(e,'submit_catalog_product_v2',jsql(request(expanded)),'invalid_request')
    # Query length is measured after Unicode whitespace trimming, before normalization.
    padded = '\u2003' * 121 + 'Synthetic cursor' + '\u00a0'
    assert rpc(e,'search_catalog_products_v2',literal(padded))['products']
    # New identity publication cannot smuggle a CAS update through a null product ID.
    expect_error(e,'submit_catalog_product_v2',jsql(request(product(),expected='1')),'invalid_request')
    # Account checks and private ACLs include stale/deleted identities and true anonymous users.
    deleted = account(); sql(f'delete from auth.users where id={literal(deleted)};')
    expect_error(deleted,'catalog_capabilities_v2','','unauthorized')
    expect_error(deleted,'submit_catalog_product_v2',jsql(request()),'unauthorized')
    anonymous=str(uuid.uuid4()); sql(f'insert into auth.users(id,is_anonymous) values({literal(anonymous)},true);')
    expect_error(anonymous,'catalog_capabilities_v2','','unauthorized')
    expect_error(str(uuid.uuid4()),'catalog_capabilities_v2','','unauthorized')
    assert sql("select has_schema_privilege('authenticated','catalog_v2','usage');")=='f'
    assert sql("select has_function_privilege('anon','public.catalog_capabilities_v2()','execute');")=='f'
    assert sql("select has_function_privilege('authenticated','catalog_v2.moderate(uuid,boolean,bigint)','execute');")=='f'
    for table in ['products','revisions','receipts','contributions','owner_reviews']:
        assert sql(f"select has_table_privilege('authenticated','catalog_v2.{table}','select');")=='f'
    sql("""set role authenticated; do $test$ begin begin perform 1 from catalog_v2.products;
      raise exception 'private table exposed' using errcode='XX000';
      exception when insufficient_privilege then null; end; end $test$;""")
    sql("""set role anon; do $test$ begin begin perform public.catalog_capabilities_v2();
      raise exception 'anonymous RPC exposed' using errcode='XX000';
      exception when insufficient_privilege then null; end; end $test$;""")
    print('SHARED PRODUCTS V2 FIXTURES, BEHAVIOR AND TWO-SESSION RACES OK')

if __name__=='__main__': main()
