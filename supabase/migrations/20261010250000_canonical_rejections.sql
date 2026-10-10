-- A rejection written with a 12-digit UPC-A must match the 13-digit form the catalog stores.
create function catalog.canonicalize_rejection() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.barcode := catalog.canonical_barcode(new.barcode);
  return new;
end;
$$;
create trigger rejections_canonical before insert or update on catalog.rejections
  for each row execute function catalog.canonicalize_rejection();
revoke all on function catalog.canonicalize_rejection() from public, anon, authenticated;

-- Rows written before the catalog stored the leading-zero form.
update catalog.rejections set barcode = catalog.canonical_barcode(barcode) where char_length(barcode) = 12;
update catalog.submissions set barcode = catalog.canonical_barcode(barcode) where char_length(barcode) = 12;
update catalog.entries set barcode = catalog.canonical_barcode(barcode) where char_length(barcode) = 12;
