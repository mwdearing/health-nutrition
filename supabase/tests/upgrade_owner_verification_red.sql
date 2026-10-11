-- Expected to fail before the forward migration: legacy five-account verification is still active.
\set ON_ERROR_STOP on
do $$ begin
  if not exists (select 1 from catalog.entries where barcode = '0123456070004'
      and basis = 'per_100g' and verified) then
    raise exception 'upgrade red precondition missing: seeded row is not automatically verified';
  end if;
  raise exception 'FAILED: pre-upgrade community row is still automatically verified';
end $$;
