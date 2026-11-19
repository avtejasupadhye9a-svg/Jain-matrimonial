# Private PC storage

The Admin app opens **Private documents** from a profile. The Worker checks the administrator’s session against DB_MAIN before it reads metadata or calls the origin. It accepts identity documents in PDF, PNG, or JPEG format up to 8 MiB. The Worker and the PC validate the file type and SHA-256. Downloads are checked against D1 again, served as private attachments, and saved through a native Windows dialog. The app checks the checksum before writing a new file.

DB_MAIN uses the existing `jm_file_metadata` table. A direct transfer reserves an opaque UUID in `copying` and sets it to `confirmed` only when the PC returns a matching object ID, checksum and length. A failed transfer can be retried by selecting the original bytes on the same document row. The PC preserves matching bytes across retries and rejects different bytes for the same UUID. D1 audit events record successful transfers and origin failures. The Admin readiness view shows disabled, unconfigured, offline, or online.

The PC must be reachable for every transfer. If the PC is offline, the request fails and its status remains visible. Temporary cloud storage, automatic offline staging, and automatic background transfer are unconfigured. The separate sync prototype remains for future staging-provider work.

## Routing proposal for approval

1. Verify ownership, management mode and connector health for the existing `jain-matrimonial-storage` Tunnel (`5ce2883f-933e-49c8-ab01-014841037d0e`). Check that the Windows PC runs its connector with QUIC or auto transport. Verify there are no conflicting connectors or public routes for the origin. [Cloudflare Tunnel for Workers VPC](https://developers.cloudflare.com/workers-vpc/configuration/tunnel/)
2. Reuse a matching VPC Service if present. Otherwise, after approval, register an HTTP VPC Service named `jain-matrimonial-storage-origin` on that Tunnel with IPv4 `127.0.0.1` and HTTP port `8765`. Use HTTP only on this same-machine loopback hop. Add the resulting service ID as the Worker’s `STORAGE_ORIGIN` binding. The proposed route requires no DNS hostname or inbound PC firewall rule. VPC Services are currently in beta. [VPC service configuration and pricing](https://developers.cloudflare.com/workers-vpc/configuration/vpc-services/)
3. Prepare the Windows service with an existing absolute storage directory on encrypted permanent storage, ACLs for its service identity, and an absolute `MpCmdRun.exe` path. Set `JAIN_STORAGE_ROOT`, `JAIN_STORAGE_DEFENDER_PATH`, and `JAIN_STORAGE_TOKEN` via secured runtime configuration. Store the same random token as the Worker secret `STORAGE_ORIGIN_TOKEN`. Keep `JAIN_STORAGE_LOCAL_TEST` unset on the service and `JAIN_LOCAL_TEST` unset on the Worker. Verify clean files and a scanner failure under the actual service identity before approvals. [Microsoft Defender command-line options](https://learn.microsoft.com/en-us/defender-endpoint/command-line-arguments-microsoft-defender-antivirus)
4. Review and approve enabling `FILE_TRANSFER_ENABLED=true` in a separate deployment after the API, PC, and private route are verified. Use synthetic documents for the first authorized inspection. Verify roles, an incorrect origin token, direct-access denial, clean/malformed documents, concurrent retries, disk errors, and unplugged-PC behavior before real documents. Disable the flag if transfer verification fails.

Proposed Wrangler binding after approval:

```toml
[[vpc_services]]
binding = "STORAGE_ORIGIN"
service_id = "<existing-or-approved-service-id>"
remote = true
```

A Cloudflare Access service-token policy on a Tunnel hostname is another supported option. It requires a DNS hostname, Service Auth policy, and scoped Access credentials. The current Worker implements the hostname-free VPC path. A broader VPC Network binding would permit access to more of the PC’s network and is unnecessary for this service. [Access service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/)

## Local testing

From the repository root, run `python -m unittest local_storage_service.test_storage -v`. From `worker`, run `npm test`. The API test starts a real isolated Python loopback origin with a synthetic scanner and tests Worker authentication, D1, upload, checksum, download, process shutdown, and retry. The test uses synthetic data.

For a manual isolated origin, open a terminal in the repository and run:

```powershell
$env:JAIN_STORAGE_LOCAL_TEST = 'true'
$env:JAIN_STORAGE_ROOT = Join-Path (Get-Location) 'local-data'
$env:JAIN_STORAGE_TOKEN = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
python -m local_storage_service.service
```
