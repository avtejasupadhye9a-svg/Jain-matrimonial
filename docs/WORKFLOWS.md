# Workflows

## Profile and publication

A verified customer records consent and creates a draft. The proposed limit is one owned profile per account, configurable through ACTIVE_PROFILE_LIMIT. Draft edits use a version check. Submission freezes the requested version and current base publication. A previous approved snapshot stays searchable until a guarded approval promotes the new snapshot. Rejection or requested corrections leave publication intact. The owner can edit a newer draft while a review is pending and submit once that review closes. Ordinary profile edits require a session only.

An administrator records the originating candidate’s authorization and matching claim email while creating an unclaimed profile. The candidate signs in with that verified email and supplies a separate claim OTP. An administrator reviews the evidence before granting ownership. The profile stays hidden until the owner explicitly enables visibility and an approved snapshot exists.

## Matchmaking and consent

Verified owners with visible approved profiles can create one interest per unordered pair. The recipient sees it after initial administrator approval. After recipient acceptance, both owners can grant scope-limited email sharing. The administrator authorizes release only with two current grants. Each contact retrieval rechecks participant identity, grants, expiry, visibility, account status and blocks. Revocation takes effect for subsequent reads. Withdrawal and cancellation are terminal. Pending and authorized interests expire after 30 days.

## Notifications and privacy

Profile, claim and interest decisions emit safe outbox events. In-app records remain available after sign-in and support unread counts and explicit read actions. The email worker leases jobs and retries with backoff. The business transaction completes independently of mail delivery. Customer-initiated deletion and export requests require fresh email verification and are available for administrator review. Operators fulfill approved requests using the documented retention process.
