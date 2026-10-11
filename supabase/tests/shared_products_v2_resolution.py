#!/usr/bin/env python3
"""Synthetic resolver acceptance, including observed overlapping profile-lock transactions."""
import copy
import json
import uuid

# Reuse only the existing disposable-Postgres transport and session barriers.
from shared_products_v2_concurrency import (
    BASE, FIXTURES, Session, account, blocked, expect_error, identity, jsql, literal,
    product, request, rpc, sql, submit,
)

RESOLVE = 'resolve_catalog_publish_for_withdrawal_v2'
SUBMIT = 'submit_catalog_product_v2'
WITHDRAW = 'withdraw_catalog_product_v2'


def resolve(a, body):
    return rpc(a, RESOLVE, jsql(body))


def call(name, body):
    return f'select public.{name}({jsql(body)})'


def error_call(name, body, code, revision=None):
    extra = '' if revision is None else f"assert d::jsonb->>'current_revision'={literal(revision)};"
    return f"""do $test$ declare d text; begin
      begin perform public.{name}({jsql(body)}); raise exception 'unexpected success' using errcode='XX000';
      exception when sqlstate 'P0001' then get stacked diagnostics d=pg_exception_detail;
      assert d::jsonb->>'code'={literal(code)}; {extra} end;
    end $test$"""


def race(a, first_query, second_query, rollback=False):
    first = Session('resolution-first-' + uuid.uuid4().hex, a)
    second = Session('resolution-second-' + uuid.uuid4().hex, a)
    try:
        first.send('begin; ' + first_query + "; select 'FIRST_HELD';")
        first.marker('FIRST_HELD')
        second.send('begin; ' + second_query + "; commit; select 'SECOND_FINISHED';")
        blocked(second)
        # Verify the winning connection, not some unrelated background lock, blocks this waiter.
        assert sql(f"""select count(*) from pg_stat_activity w,pg_stat_activity h
          where w.application_name={literal(second.name)} and h.application_name={literal(first.name)}
          and h.pid=any(pg_blocking_pids(w.pid));""") == '1'
        first.send('rollback;' if rollback else 'commit;')
        one = first.close()
        second.marker('SECOND_FINISHED')
        two = second.close()
        return one, two
    finally:
        for session in [first, second]:
            if session.p.poll() is None:
                session.send('rollback;')
                session.close()


def counts(a):
    return json.loads(sql(f"""select jsonb_build_object(
      'markers',(select count(*) from catalog_v2.publish_cancellations where account_id={literal(a)}),
      'receipts',(select count(*) from catalog_v2.receipts where account_id={literal(a)}),
      'revisions',(select count(*) from catalog_v2.revisions where account_id={literal(a)}),
      'contributions',(select count(*) from catalog_v2.contributions where account_id={literal(a)}),
      'usage',(select coalesce(sum(submissions),0) from catalog.usage where device_id={literal(a)}),
      'old_usage',(select coalesce(sum(submissions),0) from catalog_v2.usage where account_id={literal(a)}));"""))


def canceled(result, body, replayed=False):
    assert result == dict(outcome='canceled_before_commit', operation_id=str(uuid.UUID(body['operation_id'])), replayed=replayed), result


def withdraw_body(receipt):
    return dict(operation_id=str(uuid.uuid4()), client_revision_id=str(uuid.uuid4()),
                product_id=receipt['product_id'], expected_server_revision=receipt['current_revision'])


def shared_validation_authority():
    a = account(); committed = request(); marker = request()
    receipt = submit(a, committed)
    canceled(resolve(a, marker), marker)
    before = counts(a)
    # Tighten the real pure validator, preserving its owner/ACL through CREATE OR REPLACE.
    # Both fresh paths must obey this single authority; existing acknowledgments must bypass it.
    definition = sql("select pg_get_functiondef('catalog_v2.validate_operation_envelope(jsonb,boolean)'::regprocedure);")
    sql("""create or replace function catalog_v2.validate_operation_envelope(body jsonb, withdrawing boolean) returns uuid
      language plpgsql immutable security invoker set search_path='' as $$ begin
      perform catalog_v2.fail('invalid_request'); end $$;""")
    try:
        assert submit(a, committed) == dict(receipt, replayed=True)
        assert resolve(a, committed) == dict(outcome='committed', receipt=dict(receipt, replayed=True))
        canceled(resolve(a, marker), marker, True)
        expect_error(a, SUBMIT, jsql(request()), 'invalid_request')
        expect_error(a, RESOLVE, jsql(request()), 'invalid_request')
        assert counts(a) == before
    finally:
        sql(definition)
    print('PASS single pure validation authority governs fresh publication/resolution; receipts/markers bypass it')


def fresh_validation():
    a = account()
    initial_products = sql('select count(*) from catalog_v2.products;')
    assert rpc(a, 'catalog_capabilities_v2')['publish_resolution_version'] == 1
    valid = ['name-only-valid', 'fact-states-valid', 'unicode-120-valid', 'barcode-valid',
             'amount-max-valid', 'key-identity-valid', 'exact-16384-valid']
    invalid = ['nested-private-invalid', 'serving-private-invalid', 'unicode-121-invalid',
               'barcode-checksum-invalid', 'amount-over-max-invalid', 'dimension-invalid',
               'unknown-standard-invalid', 'threshold-amount-invalid', 'key-duplicate-invalid',
               'oversize-16385-invalid']
    for name in valid:
        body = json.loads((FIXTURES / (name + '.json')).read_text())
        body['operation_id'] = str(uuid.uuid4())
        canceled(resolve(a, body), body)
        canceled(resolve(a, body), body, True)
    before = counts(a)
    for name in invalid:
        body = json.loads((FIXTURES / (name + '.json')).read_text())
        body['operation_id'] = str(uuid.uuid4())
        expect_error(a, RESOLVE, jsql(body), 'invalid_request')
        expect_error(a, SUBMIT, jsql(body), 'invalid_request')
    base = request()
    malformed = [None, [], {}, dict(base, notes='private'), dict(base, operation_id=None),
                 dict(base, operation_id=uuid.uuid4().hex), dict(base, client_revision_id=None),
                 dict(base, client_revision_id=2), dict(base, client_revision_id='invalid'),
                 dict(base, product_id=3), dict(base, product_id='invalid'),
                 dict(base, expected_server_revision='1'), dict(base, expected_server_revision=0),
                 dict(base, consent_generation=None), dict(base, consent_generation='0\n'),
                 dict(base, consent_version='2'), dict(base, product=None)]
    for key in base:
        body = dict(base); del body[key]; malformed.append(body)
    for body in malformed:
        expect_error(a, RESOLVE, jsql(body), 'invalid_request')
        expect_error(a, SUBMIT, jsql(body), 'invalid_request')
    assert counts(a) == before
    assert before == dict(markers=len(valid), receipts=0, revisions=0, contributions=0, usage=0, old_usage=0)
    assert sql('select count(*) from catalog_v2.products;') == initial_products
    # Nonexistent product, stale CAS, and stale consent are well-formed cancellation requests.
    body = request(pid=str(uuid.uuid4()), expected='999999999999999999999999', generation='999')
    canceled(resolve(a, body), body)
    # Exact UTF-8 identity (not Swift-style canonical-equivalent String equality), numeric/UUID spelling.
    for body, change in [
        (request(product('Caf\u00e9')), lambda b: b['product'].update(name='Cafe\u0301')),
        (request(), lambda b: b['product']['facts'][0].update(amount='1.0')),
        (request(), lambda b: b.update(operation_id=b['operation_id'].upper())),
    ]:
        canceled(resolve(a, body), body)
        changed = copy.deepcopy(body); change(changed)
        expect_error(a, RESOLVE, jsql(changed), 'operation_conflict')
        expect_error(a, SUBMIT, jsql(changed), 'operation_conflict')
        cancellation_withdraw = dict(operation_id=body['operation_id'], client_revision_id=str(uuid.uuid4()),
                                     product_id=str(uuid.uuid4()), expected_server_revision='1')
        expect_error(a, WITHDRAW, jsql(cancellation_withdraw), 'operation_conflict')
    # Unknown/dead/anonymous owners cannot insert; another live owner has its own UUID namespace.
    body = request(); canceled(resolve(a, body), body)
    other = account(); canceled(resolve(other, body), body)
    expect_error(str(uuid.uuid4()), RESOLVE, jsql(request()), 'unauthorized')
    sql(f'update auth.users set is_anonymous=true where id={literal(other)};')
    expect_error(other, RESOLVE, jsql(request()), 'unauthorized')
    sql("set role authenticated; set request.jwt.claim.sub=''; " + error_call(RESOLVE, request(), 'unauthorized') + ';')
    print('PASS full fresh validation, exact canonical identity, owner isolation, zero publication effects')


def policy_and_replays():
    a = account(); body = request(); receipt = submit(a, body)
    sql(f"update public.profiles set share_labels=false where id={literal(a)}; update catalog_v2.settings set enabled=false; update catalog.settings set daily_limit=1;")
    first = request(generation='0')
    canceled(resolve(a, first), first)
    no_ack = str(uuid.uuid4()); sql(f'insert into auth.users(id) values({literal(no_ack)});')
    canceled(resolve(no_ack, first), first)
    result = resolve(a, body)
    assert result['outcome'] == 'committed' and result['receipt']['replayed']
    assert result['receipt']['product_id'] == receipt['product_id']
    sql(f"select catalog_v2.moderate({literal(receipt['product_id'])},true);")
    assert resolve(a, body)['receipt']['current_state'] == 'rejected'
    removed = rpc(a, WITHDRAW, jsql(withdraw_body(receipt)))
    result = resolve(a, body)['receipt']
    assert result['acknowledged_revision'] == receipt['acknowledged_revision']
    assert result['current_revision'] == removed['current_revision'] and result['current_state'] == 'withdrawn'
    # Existing receipts and markers bypass fresh product validation (synthetic future-rule change).
    sql('begin; alter function catalog_v2.valid_product(jsonb) rename to valid_product_saved; '
        "create function catalog_v2.valid_product(jsonb) returns boolean language sql as 'select false'; commit;")
    try:
        assert resolve(a, body)['outcome'] == 'committed'
        canceled(resolve(a, first), first, True)
    finally:
        sql('begin; drop function catalog_v2.valid_product(jsonb); alter function catalog_v2.valid_product_saved(jsonb) rename to valid_product; commit;')
    expect_error(a, RESOLVE, jsql(dict(body, consent_generation='2')), 'operation_conflict')
    # Matching a withdrawal receipt is a conflict, even before fresh envelope validation.
    expect_error(a, RESOLVE, jsql(dict(body, operation_id=removed['operation_id'])), 'operation_conflict')
    sql('update catalog_v2.settings set enabled=true;')
    # Cancellation survives withdrawal-all and consent off/on; only deletion may remove a marker.
    rpc(a, 'withdraw_my_submissions')
    sql(f'update public.profiles set share_labels=true where id={literal(a)};')
    rpc(a, 'acknowledge_catalog_consent_v2', '2')
    expect_error(a, SUBMIT, jsql(first), 'operation_conflict')
    canceled(resolve(a, first), first, True)
    sql('update catalog_v2.settings set max_new_publish_cancellations_per_day=1;')
    try:
        canceled(resolve(a, first), first, True)
        assert resolve(a, body)['outcome'] == 'committed'
        before = counts(a)
        query = error_call(RESOLVE, request(), 'rate_limited').replace("assert d::jsonb->>'code'='rate_limited';",
             "assert d::jsonb->>'code'='rate_limited'; assert (d::jsonb->>'retry_after_seconds')::integer between 1 and 86400;")
        sql(identity(a) + query + ';')
        assert counts(a) == before
    finally:
        sql('update catalog_v2.settings set max_new_publish_cancellations_per_day=256;')
    # The UTC insertion day is independent of session timezone and DST/calendar-day arithmetic.
    sql('update catalog_v2.settings set max_new_publish_cancellations_per_day=1;')
    try:
        for zone in ['Pacific/Kiritimati', 'America/Adak']:
            owner = account(); yesterday = request(); today = request()
            canceled(resolve(owner, yesterday), yesterday)
            sql(f"update catalog_v2.publish_cancellations set created_at=(date_trunc('day',now() at time zone 'UTC') at time zone 'UTC')-interval '1 microsecond' where account_id={literal(owner)};")
            result = json.loads(sql(f"set timezone={literal(zone)}; " + identity(owner) + call(RESOLVE, today) + ';'))
            canceled(result, today)
            sql(f"update catalog_v2.publish_cancellations set created_at=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC' where account_id={literal(owner)} and operation_id={literal(today['operation_id'])};")
            sql(f"set timezone={literal(zone)}; " + identity(owner) + error_call(RESOLVE, request(), 'rate_limited') + ';')
            canceled(resolve(owner, today), today, True)
    finally:
        sql('update catalog_v2.settings set max_new_publish_cancellations_per_day=256;')
    print('PASS UTC-day budget boundaries in UTC+14 and UTC-9, independent of publication accounting')
    sql('update catalog.settings set daily_limit=1000;')
    print('PASS off/disabled/stale consent, replay-before-validation, moderation/current state, exhausted publication quota')


def concurrency():
    # 1. Publication holds the profile first. Rollback must leave no identity allocation behind.
    for rollback in [False, True]:
        a = account(); body = request(); products_before = int(sql('select count(*) from catalog_v2.products;'))
        one, two = race(a, call(SUBMIT, body), call(RESOLVE, body), rollback)
        if rollback:
            canceled(two[0], body)
            assert counts(a) == dict(markers=1, receipts=0, revisions=0, contributions=0, usage=0, old_usage=0)
        else:
            assert two[0]['outcome'] == 'committed'
            assert two[0]['receipt'] == dict(one[0], replayed=True)
            assert counts(a) == dict(markers=0, receipts=1, revisions=1, contributions=1, usage=1, old_usage=0)
        assert int(sql('select count(*) from catalog_v2.products;')) == products_before + (not rollback)
    print('PASS race publication wins and rollback')
    # 2. Cancellation holds first. Commit fences both writers forever; rollback permits publication.
    for rollback in [False, True]:
        a = account(); body = request()
        one, two = race(a, call(RESOLVE, body), call(SUBMIT, body) if rollback else error_call(SUBMIT, body, 'operation_conflict'), rollback)
        if rollback:
            assert not two[0]['replayed']
            assert counts(a) == dict(markers=0, receipts=1, revisions=1, contributions=1, usage=1, old_usage=0)
        else:
            assert counts(a) == dict(markers=1, receipts=0, revisions=0, contributions=0, usage=0, old_usage=0)
            sql(f'update public.profiles set share_labels=false where id={literal(a)}; update public.profiles set share_labels=true where id={literal(a)};')
            rpc(a, 'acknowledge_catalog_consent_v2', '2')
            expect_error(a, SUBMIT, jsql(body), 'operation_conflict')  # A new psql connection.
            canceled(resolve(a, body), body, True)
    print('PASS race cancellation wins and rollback, permanent fence across fresh connection/consent')
    # 3. Matching resolver, different canonical body and daily budget all serialize.
    a = account(); body = request()
    one, two = race(a, call(RESOLVE, body), call(RESOLVE, body))
    canceled(one[0], body); canceled(two[0], body, True); assert counts(a)['markers'] == 1
    a = account(); body = request(); changed = copy.deepcopy(body); changed['product']['name'] += ' changed'
    race(a, call(RESOLVE, body), error_call(RESOLVE, changed, 'operation_conflict'))
    assert counts(a)['markers'] == 1
    sql('update catalog_v2.settings set max_new_publish_cancellations_per_day=1;')
    try:
        a = account(); body = request()
        race(a, call(RESOLVE, body), error_call(RESOLVE, request(), 'rate_limited'))
        assert counts(a)['markers'] == 1
    finally:
        sql('update catalog_v2.settings set max_new_publish_cancellations_per_day=256;')
    print('PASS race resolver idempotency, canonical conflict and quota boundary')
    # 4. Cancel an existing-product update without claiming the preceding contribution is removed.
    a = account(); first = submit(a, request()); update = request(product('Synthetic canceled update'), first['product_id'], first['current_revision'])
    before = counts(a)
    race(a, call(RESOLVE, update), error_call(SUBMIT, update, 'operation_conflict'))
    current = rpc(a, 'get_my_catalog_contribution_v2', literal(first['product_id']))
    assert current['current_state'] == 'active' and current['current_revision'] == first['current_revision']
    assert counts(a) == dict(before, markers=1)
    assert rpc(a, 'search_catalog_products_v2', "'Synthetic canceled update'")['products'] == []
    assert rpc(a, WITHDRAW, jsql(withdraw_body(first)))['current_state'] == 'withdrawn'
    print('PASS race existing update cancellation preserves earlier contribution, later CAS withdrawal')
    # 5. Deliberate newer publication wins against a withdrawal prepared from the resolved receipt.
    a = account(); original = request(); first = submit(a, original)
    assert resolve(a, original)['receipt']['acknowledged_revision'] == first['acknowledged_revision']
    update = request(pid=first['product_id'], expected=first['current_revision'])
    # Capture the actual next revision while the winning transaction holds its row lock.
    first_session = Session('resolution-newer-' + uuid.uuid4().hex, a)
    second_session = Session('resolution-stale-' + uuid.uuid4().hex, a)
    first_session.send('begin; ' + call(SUBMIT, update) + "; select 'NEWER_HELD';")
    first_session.marker('NEWER_HELD')
    newer = next(json.loads(line) for line in first_session.lines if line.startswith('{'))
    second_session.send('begin; ' + error_call(WITHDRAW, withdraw_body(first), 'revision_conflict', newer['current_revision']) + "; commit; select 'STALE_DONE';")
    blocked(second_session)
    assert sql(f"select count(*) from pg_stat_activity w,pg_stat_activity h where w.application_name={literal(second_session.name)} and h.application_name={literal(first_session.name)} and h.pid=any(pg_blocking_pids(w.pid));") == '1'
    first_session.send('commit;'); first_session.close(); second_session.marker('STALE_DONE'); second_session.close()
    assert rpc(a, 'get_my_catalog_contribution_v2', literal(first['product_id']))['current_revision'] == newer['current_revision']
    old_withdraw = withdraw_body(newer); removed = rpc(a, WITHDRAW, jsql(old_withdraw))
    republished = submit(a, request(pid=first['product_id'], expected=removed['current_revision']))
    replay = rpc(a, WITHDRAW, jsql(old_withdraw))
    assert replay['current_state'] == 'active' and replay['current_revision'] == republished['current_revision']
    assert replay['publication'] is not None
    print('PASS race later publication rejects stale withdrawal; old withdrawal replay shows republished state')
    # 6. Deletion in either order, plus rollback. No orphan markers or stale-token resurrection.
    a = account(); body = request()
    race(a, call(RESOLVE, body), 'select public.delete_my_account()')
    assert counts(a) == dict(markers=0, receipts=0, revisions=0, contributions=0, usage=0, old_usage=0)
    expect_error(a, RESOLVE, jsql(body), 'unauthorized')
    a = account(); body = request()
    race(a, 'select public.delete_my_account()', error_call(RESOLVE, body, 'unauthorized'))
    assert counts(a)['markers'] == 0
    a = account(); body = request()
    _, two = race(a, 'select public.delete_my_account()', call(RESOLVE, body), rollback=True)
    canceled(two[0], body)
    assert counts(a)['markers'] == 1
    print('PASS race deletion both orders and rollback, no marker resurrection')


def main():
    sql('update catalog.settings set daily_limit=1000;')
    shared_validation_authority()
    fresh_validation()
    policy_and_replays()
    concurrency()
    assert sql('select count(*) from catalog_v2.receipts r join catalog_v2.publish_cancellations c using(account_id,operation_id);') == '0'
    print('PASS all publication resolution acceptance tests')


if __name__ == '__main__':
    main()
