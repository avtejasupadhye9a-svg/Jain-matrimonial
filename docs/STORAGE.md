# Storage and Tunnel

The existing Tunnel is jain-matrimonial-storage. The local cloudflared binary was found. Remote Tunnel inspection requires an authenticated Cloudflare context and local service status requires permission to query the Windows service. A Tunnel ID cannot be addressed by the Worker as a binding.

The Python origin uses a configurable directory, loopback, bearer authentication, random UUID object keys, an eight-megabyte limit, size and MIME signature checks, SHA-256 verification, a scanner callback, immutable writes and verified retries. Its executable configuration permits synthetic local test mode only. Limit directory access to the service account and use an encrypted volume before storing sensitive files. Native apps show uploads unavailable and the Worker returns storage_unavailable.

## Future approved route

1. Verify the existing Tunnel and its connector are healthy. Choose a hostname under a Cloudflare-managed domain.
2. Configure an Access self-hosted app with Service Auth limited to the Worker’s service token. Configure an ingress route for that hostname to the local loopback origin and ensure no direct or bypass route is reachable.
3. Store Access client ID and secret and a separate origin authorization token as Worker secrets. On outbound HTTPS requests attach CF-Access-Client-Id and CF-Access-Client-Secret plus the independent origin authentication. Disable redirects for secret-bearing requests. Verify unauthenticated requests fail at Access and incorrect origin authorization fails at the origin.
4. Configure a private staging provider and authenticated credentials, a real scanner, access logs, a durable sync journal and retention schedules. Test denied/expired tokens, retries, concurrent writes, partial/corrupt files, disk-full and PC-off cases before enabling any production transfer.

These steps are pending owner approval. See [Cloudflare Access service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/).

The copy protocol confirms the permanent checksum and journals the confirmation before conditionally removing staging bytes. A worker can safely repeat after loss of the acknowledgment. If the permanent copy is missing or corrupted, retain staging. Provider adapters must make conditional deletion safe for concurrent changes. A SQLite journal persists local confirmations across restarts. Test doubles cover staging and the protocol. Durable queue execution, retrieval, malware scanning and production adapters need configuration and implementation before file service launch.



## Local origin check

Use a dedicated test directory. From the repository root, run the service in a separate PowerShell window with a generated synthetic token retained in that terminal only.

```powershell
$env:JAIN_STORAGE_LOCAL_TEST = 'true'
$env:JAIN_STORAGE_ROOT = Join-Path (Get-Location) 'local-data'
$env:JAIN_STORAGE_TOKEN = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
python -m local_storage_service.service
```

Run the automated loopback health and authentication checks with python -m unittest local_storage_service.test_storage -v. The local service process uses synthetic scanner behavior in this mode.
