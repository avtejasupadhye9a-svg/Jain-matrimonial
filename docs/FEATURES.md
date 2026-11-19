# Feature status

| Area | Source available | Verification and remaining scope |
|---|---|---|
| Auth | Customer email OTP and security challenges. One Admin password, private D1 setup, change password, rotating sessions, and revocation. | Production sender, migration, Admin setup, and password latency require verification. |
| Candidate profiles | Draft wizard, claim, pending immutable revisions, visibility and suspension | Conservative publication policy awaits owner sign-off |
| Discovery | Approved profile filter, details, saved searches, favorites, preference prefill and recommendations | Recommendation candidates are bounded to the 500 most recently published eligible profiles |
| Matchmaking | Admin review, recipient response, mutual consent, final authorization, withdrawal, blocks, reports and contact revocation | Verified email scope only |
| Updates | Durable in-app inbox, unread count, audit, email queue with retry | Mock failure and retry covered. Live mail and Android push unconfigured |
| Android customer | API-connected sign in, profile, discovery, interests, updates and privacy screens | See SETUP for dependencies and local verification |
| Windows admin | API-connected moderation dashboard, profile diff, claims, accounts, interests, reports, privacy requests and readiness | See SETUP for dependencies and local verification |
| Data rights | Customer request submission and admin queue | Audited closure is available. Operator fulfillment and retention need production policy |
| Storage | Local private origin, upload verification and staged copy contract | Transfers disabled. Provider, scanner, durable scheduler, retrieval and Tunnel routing pending |
