#!/usr/bin/env python3
"""Suspend the active old authenticated RPC immediately before its legacy verified write.

A test-only advisory barrier leaves the old aggregation/write expressions intact;
the old function resumes after the exact migration commits. The table invariant must reject its stale
verified write. The negative control removes only that invariant in a disposable DB.
"""
import subprocess
import sys
import threading
import time
from pathlib import Path

engine, container, database, mode = sys.argv[1:]
base = [engine, 'exec', '-i', container, 'psql', '-X', '-U', 'postgres', '-d', database,
        '-v', 'ON_ERROR_STOP=1', '-Atq']

def sql(q):
    r = subprocess.run(base, input=q, text=True, capture_output=True, timeout=30)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()

class Session:
    def __init__(self):
        self.p = subprocess.Popen(base, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, bufsize=1)
        self.lines = []
        self.reader = threading.Thread(target=lambda: self.lines.extend(self.p.stdout), daemon=True)
        self.reader.start()
    def send(self, q):
        self.p.stdin.write(q + '\n'); self.p.stdin.flush()
    def marker(self, text):
        end = time.monotonic() + 15
        while time.monotonic() < end:
            if any(x.strip() == text for x in self.lines): return
            if self.p.poll() is not None: raise AssertionError(self.p.stderr.read())
            time.sleep(.03)
        raise AssertionError('migration barrier timeout')
    def finish(self):
        self.p.stdin.close(); self.p.wait(timeout=20); self.reader.join(timeout=2)
        return self.p.returncode, self.p.stderr.read()

migration = Path('supabase/migrations/20261011203625_catalog_owner_verification.sql').read_text()
if mode == 'negative-control':
    migration = migration.replace('alter table catalog.entries\n  add constraint catalog_entries_community_unverified_check check (not verified) not valid;', '')
    migration = migration.replace('alter table catalog.entries validate constraint catalog_entries_community_unverified_check;', '')
assert migration.rstrip().endswith('commit;')
# Instrument only the disposable pre-upgrade function with a scheduling barrier. Its
# original aggregation and verified-write expressions execute unchanged after release.
old_definition = sql("select pg_get_functiondef('catalog.refresh_entry(text,text)'::regprocedure);")
needle = '  insert into catalog.entries ('
assert old_definition.count(needle) == 1
sql(old_definition.replace(needle, '  perform pg_advisory_xact_lock(8675309001);\n' + needle))
# A newly submitted key is invisible to the migration's rebuild until the old writer commits.
# Use the supported two-account legacy threshold; the old body computes verified=true.
# An additional committed submission has no derived entry yet; the racing second
# contribution reaches the supported two-account threshold on the same new key.
sql("""update catalog.settings set min_shown=2, min_devices=2;
insert into catalog.submissions(device_id,barcode,basis,product_name,nutrients)
values ('00000000-0000-0000-0000-000000009002','96385074','per_100g','Synthetic racing label',
'{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}');""")
barrier = Session()
barrier.send("begin; select pg_advisory_xact_lock(8675309001); select 'BARRIER_HELD';")
barrier.marker('BARRIER_HELD')
old = Session()
old.send("""set application_name='owner-upgrade-old-writer'; set statement_timeout=15000;
set request.jwt.claim.sub='00000000-0000-0000-0000-000000009001';
set request.jwt.claims='{"is_anonymous":false}'; set role authenticated;
select public.submit_label('96385074','per_100g',null,'Synthetic racing label',null,
'{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}'::jsonb);
""")
end = time.monotonic() + 12
while time.monotonic() < end:
    if sql("select count(*) from pg_stat_activity where application_name='owner-upgrade-old-writer' and wait_event='advisory';") == '1': break
    time.sleep(.03)
else: raise AssertionError('old authenticated RPC never entered the lock barrier')
# Withdraw the committed helper submission while the old function already holds its
# computed aggregate. The uncommitted racing contribution remains invisible to rebuild.
sql("delete from catalog.submissions where barcode='96385074' and device_id='00000000-0000-0000-0000-000000009002';")
# The migration replaces the function while its old invocation is suspended before INSERT.
sql(migration)
barrier.send('commit;')
code, err = barrier.finish(); assert code == 0, err
code, err = old.finish()
if mode == 'negative-control':
    assert code == 0, err
    assert sql("select verified from catalog.entries where barcode='96385074';") == 't'
    print('RED reproduced: old authenticated RPC restored verified=true without invariant')
else:
    assert code != 0 and 'catalog_entries_community_unverified_check' in err, err
    assert sql("select count(*) from catalog.entries where verified;") == '0'
    print('Upgrade race OK: overlapping old authenticated RPC rejected by table invariant')
