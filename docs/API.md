# REST API

Native clients send Authorization: Bearer ACCESS_TOKEN. JSON writes use Content-Type: application/json. State transitions and new records that can be duplicated require Idempotency-Key, a 16–100 character request identifier. Retry the same method, path, body and key. Completed requests replay their receipt. If a process crashes before saving a receipt, the key stays reserved and returns a conflict. Refresh the resource before choosing whether to issue a new action.

```json
{"code":"ok","message":"Request completed.","requestId":"uuid","data":{"status":"ok"}}
```

```json
{"code":"invalid_input","message":"Check the submitted fields.","requestId":"uuid","fields":{"dob":"Enter a valid date."}}
```

HTTP 401 means sign-in is required, 403 means forbidden, 404 means unavailable to the caller, 409 means stale or already processed, 429 means throttled, and 503 means unavailable. Lists take limit (1–50) and offset and return items and nextOffset. Notifications also return unread. For discovery, send the same filters and the returned nextCursor for each following page. The cursor is encrypted and bound to the current account and filters. The API denies browser origins unless explicitly allowlisted.

| Access | Method and route | Input or purpose |
|---|---|---|
| Public | GET /health | Minimal process response |
| Public | POST /auth/otp/request, /auth/otp/verify | email, or challengeId and six-digit code |
| Public | POST /auth/refresh | refreshToken, rotated on success |
| Signed in | GET /me, POST /auth/logout | Session details or revoke current session |
| Signed in | POST /auth/security-code | Fresh verified-email challenge |
| Customer | POST /auth/claim-code, /auth/new-email-code, /auth/change-email | Claim challenge, new email challenge, or email and current/next challenge pairs |
| Customer | GET/POST /profiles | Owned drafts or create with consent and data |
| Signed in | GET/PUT /profiles/{id}, POST /profiles/{id}/submit | Authorized detail, save data with version, or submit the current version |
| Customer | PUT /profiles/{id}/visibility, POST /profiles/claim | visible; profileId and scoped challenge |
| Customer | GET /search, /discover/{id}, /recommendations | Approved publication with privacy projections |
| Customer | GET /favorites, PUT/DELETE /favorites/{id} | Favorites scoped to current account |
| Customer | GET/POST /saved-searches, PUT/DELETE /saved-searches/{id} | name and filters for writes |
| Customer | GET/POST /interests, POST /interests/{id}/decision | sender and recipient on create; action and version on decision |
| Customer | PUT /interests/{id}/consent, GET /interests/{id}/contact | granted Boolean, or consent-gated verified email |
| Customer | PUT/DELETE /blocks/{id}, POST /reports | Block profile owner account, or profileId and reason |
| Customer | GET /claims, /privacy-requests | Own claim and request status |
| Customer | POST /privacy-requests | kind plus security challenge |
| Signed in | GET /notifications, POST /notifications/{id}/read | Owned inbox |
| Signed in | /files/* | 503 while storage is disabled |
| Admin | GET /readiness, /admin/dashboard | Integration flags and pending counts |
| Admin | GET /admin/profiles, /admin/revisions, /admin/claims, /admin/accounts | Moderation queues; profiles and accounts accept q |
| Admin | GET /admin/interests, /admin/reports, /admin/blocks, /admin/privacy-requests, /admin/audit | Operational queues and audit |
| Admin | POST /admin/profiles | data, consent, claimEmail and consentEvidence |
| Admin | POST /admin/revisions/{id}/decision, /admin/claims/{id}/decision | decision and reason |
| Admin | GET /admin/moderation/{id}, POST /admin/privacy-requests/{id}/close | Restricted moderation reasons or close a fulfilled data request |
| Admin | POST /admin/interests/{id}/decision, /admin/reports/{id}/close | action/version/reason or report close reason |
| Admin | PUT /admin/profiles/{id}/suspension, /admin/accounts/{id}/suspension | suspended and reason |
| Local test only | POST /_local/admin, /_local/reconcile | Guarded synthetic admin bootstrap and outbox replay |

Search filters include ID, age/height intervals, city/state/district/country, qualification/degree, occupation/employment type/income band, marital status, tradition/sub-community, diet, language, relocation and sort. Publication projections omit exact DOB, login identifiers, candidate name, family details and employer. Eligible profile details add preselected structured fields. Contact details use a separate, dynamically checked endpoint.
