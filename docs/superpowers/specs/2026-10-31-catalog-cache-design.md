# Catalog cache and local-first search design (NF-10)

Status: proposed, waiting for owner decisions. Nothing here is built. Each choice below names a recommended option, and
the ones marked **owner decision** change something a person sees or what the app stores, so they wait for an answer
before any code is written.

This is the design for #86 (NF-10): an offline cache of catalog products, source and licence attribution and evidence
badges kept with each cached product, and local, manual and favourite operations that keep working while the catalog is
unreachable. It is the prerequisite of #87 (NF-11), which freezes the selected product version into the intake
revision.

## What exists today

- Barcode lookups go to the community catalog only, and only for a signed-in person
  ([community catalog in the app](../../community-catalog-app.md)). A catalog failure reads as "No product found for
  that barcode."
- Shared products are searched through `search_catalog_products_v2` and opened through `get_catalog_product_v2`
  ([community client](../../community-client.md)). Discovery opens a read-only facts inspector before a deliberate
  Save.
- Search shows Library rows (favourites, saved meals, recents, custom products) from the device first, then catalog
  results. There is no cache of catalog results: a product that was not saved to the Library is gone once the screen
  closes, and nothing from the catalog is available offline (PR #240 added a signed-in network fallback, not a cache).
- A logged entry already keeps its own immutable product snapshot (`JournalStoreTests.testProductSnapshotStaysImmutableAcrossEdit`),
  so the journal never depends on the catalog being reachable.
- The server side of a published-only search, detail and barcode service (NF-08, nutrition-catalog#9) is not done. This
  design uses only the v2 calls the client already has.

## Choices

### 1. What is cached — owner decision

- **A. Recommended: what the person has seen.** A catalog product the person opened, looked up by barcode or logged is
  kept, up to a cap (500 products, oldest-opened dropped first). Nothing is fetched in the background.
- B. A downloaded slice of the catalog (for example the most common products), refreshed on a schedule. More works
  offline, but it means background traffic, a much larger store and a sync design the backend does not have yet.

### 2. Where it is stored — owner decision (schema)

- **A. Recommended: a fifth SwiftData store, `catalog-cache.store`**, next to the four existing stores. It holds only
  catalog copies, never anything the person wrote. It is cleared by Erase all data and by signing out, it is not part
  of the journal export, and it follows the same file erasure as the other stores (#228).
- B. Rows inside the journal store. Fewer files, but every cache refresh would be a journal write, and the export and
  restore code would have to learn to skip them.

### 3. Freshness

- **A. Recommended: no fixed expiry, refreshed when seen online.** A cached product is shown as it was cached and
  refreshed the next time the catalog answers for it. A product the catalog withdraws, rejects or replaces is removed
  or replaced in the cache when the catalog says so. A cache entry is never used to rewrite a logged entry: the
  entry's own snapshot stays as it was (#87).
- B. A fixed expiry (for example 30 days), after which a cached product is hidden until it is fetched again.

Either way a withdrawal, rejection or recall reaches a phone's cache only when that phone next fetches the product,
so a phone that stays offline keeps showing what it saved. Option A makes that visible rather than hiding it: every
cached product shows when it was saved ("Saved on this phone on Oct 31", choice 6), and after 90 days without the
catalog confirming it, the product is still shown but without its verification badge until it is fetched again. That
90-day limit is part of the owner decision.

### 4. Search order and the offline state — owner decision (copy)

- **A. Recommended: device first, then cache, then the catalog.** Library rows come first as today, then cached
  catalog products that match, then live catalog results, with a live result replacing its cached copy. When the
  catalog cannot be reached the screen shows what the device and cache have, with one line under them. The proposed
  wording, for approval: "Can't reach the shared catalog. Showing products saved on this phone."
- B. Keep the catalog results and the cached ones in separate sections.

### 5. Signed-out use — owner decision

- **A. Recommended: the cache belongs to the signed-in account.** It is filled only from signed-in lookups (the app
  makes no catalog call signed out today), and it is cleared on sign-out, so a shared phone does not show one
  person's lookups to the next.
- B. Keep the cache across sign-out and let a signed-out person search it.

### 6. Attribution and evidence badges

- **A. Recommended: cached exactly as received.** Each cached product keeps the source, licence and verification
  source the catalog sent (`community` or `owner_reviewed`), and the screen shows the same attribution line and badge
  as for a live result. A cached product also shows when it was cached. The proposed wording, for approval:
  "Saved on this phone on Oct 31". A missing or unknown source still fails closed, as it does live.

### 7. Operations that must keep working offline

Logging from the Library, manual entry, favourites, saved meals, recipes, repeating an entry and logging a cached
product all work with no connection, because none of them needs the catalog. Sharing a label and publishing a product
keep their existing rules (an upload that fails is not retried; a publication stays recoverable).

## Tests

Mock-server tests in the providers and UI layers, with no network: a lookup that succeeds fills the cache; the same
lookup offline is answered from the cache with its attribution; a withdrawal reply removes the cached product; sign-out
and Erase all data leave the cache empty; the cache cap drops the oldest-opened product; a logged entry's snapshot does
not change when its cached product is refreshed.

## Not in this design

The backend service of NF-08, any background download, and the version freeze of #87 itself. Device acceptance of the
offline screens is separate evidence.
