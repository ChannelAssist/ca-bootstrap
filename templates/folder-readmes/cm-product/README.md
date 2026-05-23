# cm-product

ChannelManager product repos. The application services and shared libraries
that make up the ChannelManager product — they share the `cm-*` prefix.

## What lives here

- `channel-manager` — legacy monolith (≈4 GB; opt-in clone).
- `cm-claims-validator` — claims validation service.
- `cm-contracts` — contract definitions / OpenAPI.
- `cm-currency-service` — currency conversion service.
- `cm-database-infra` — database schema + migrations.
- `cm-platform-infra` — shared platform infrastructure.
- `cm-purchase-order-service` — purchase order service.
- `cm-service-template` — template for new cm-* services.
- `cm-shared-libs` — shared library code.

## Tree

```
cm-product/
├── channel-manager/             # legacy monolith (opt-in, ≈4 GB)
├── cm-claims-validator/
├── cm-contracts/
├── cm-currency-service/
├── cm-database-infra/
├── cm-platform-infra/
├── cm-purchase-order-service/
├── cm-service-template/
└── cm-shared-libs/
```

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
