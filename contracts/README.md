# Contracts

Shared, language-neutral definitions that the iOS app and the catalog service
both build against. Examples in this tree are synthetic.

- `nutrients/` - the nutrient vocabulary: identifiers, units and conversions.
- `catalog-api/` - the HTTP contract of the catalog service.
- `providers/` - how external food-data providers map into the catalog.

Schema validation in CI will be added together with the first contract.
