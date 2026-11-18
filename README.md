# Jain Matrimonial

A Windows-developed monorepo for an admin-controlled matrimonial service.

- customer_app contains the Flutter Android customer application.
- admin_app contains the Flutter Windows administrator application.
- client_shared contains the session client, common response types, forms and UI components.
- worker contains the Cloudflare Worker API and local D1 migrations for both existing bindings.
- local_storage_service contains a loopback-only private storage origin and copy protocol.
- scripts contains local setup and verification scripts.

Start with [Windows setup](docs/SETUP.md). See [feature status](docs/FEATURES.md), [API](docs/API.md), [database](docs/DATABASE.md), [workflows](docs/WORKFLOWS.md), [security](docs/SECURITY.md), [architecture](docs/ARCHITECTURE.md), [storage](docs/STORAGE.md), and the [deployment gate](docs/DEPLOYMENT.md).

The production API base is https://jain-matrimonial-api.avtejasupadhye-9a.workers.dev. Local development uses isolated databases and synthetic fixture identities. Temporary file staging, live file transfer, SMS and Android push require separate provider configuration.
