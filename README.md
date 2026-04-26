# ns8-ssh-access-manager

NethServer 8 module for [ssh-access-manager](https://github.com/stephdl/ssh-access-manager) — an SSH access audit and management tool running in a single Alpine Linux container.

## What it does

ssh-access-manager audits SSH access across a fleet of Linux servers without requiring root access for day-to-day operations. All interactions with remote servers go through a dedicated **non-root Unix user** (`audit-collector` by default) with a minimal and explicit `sudo` delegation.

### How remote server access works

A dedicated Unix user (`audit-collector`) is created on each remote server during provisioning. This user connects via SSH using an ED25519 key pair generated inside the container, and is granted `sudo` rights **only** for the following scripts — nothing else:

| Script | Purpose |
|---|---|
| `sam-collect` | Lists all `authorized_keys` entries across all Unix users — used for periodic inventory scans |
| `sam-revoke` | Removes a specific key from `authorized_keys` by SHA256 fingerprint, using an atomic rewrite (`mktemp` + `mv`) |
| `sam-add` | Creates a Unix user if needed, then adds a public key to `authorized_keys` with correct permissions |
| `sam-lock-user` | Runs `usermod -L -s /sbin/nologin <user>` — blocks SSH access even with a valid key |
| `sam-unlock-user` | Runs `usermod -U -s /bin/bash <user>` — restores normal access |

These scripts are embedded in the container image, deployed to each host via SFTP, and updated automatically when their SHA256 hash changes (tracked in the audit log).

### Key lifecycle and alerting

- **Inventory**: on first scan, all existing keys are imported with status `PENDING_REVIEW` and a CRITICAL email alert is sent for each unknown key.
- **Weak key detection**: key conformity is checked against ANSSI recommendations (BP-099). `ssh-ed25519` keys are always compliant; `ssh-rsa` requires ≥ 4096 bits. Non-compliant keys are flagged with a ⚠️ badge in the UI.
- **Expiration**: keys can be given an expiration date or a duration in hours. Two warning emails are sent before expiry (configurable via `expire_warn_days` and `expire_warn_days_2`). Revocation is automatic at expiry.
- **Anomaly detection**: if a key disappears from `authorized_keys` without going through the system, or if a previously revoked key reappears (e.g. via `ssh-copy-id`), a CRITICAL alert is sent immediately.

### Key deployment

From the web UI (Access tab → Deploy SSH key), administrators can deploy a new public key to any active server. The form collects the target Unix user (created if it does not exist), the public key, the target server, an optional expiration, and a mandatory justification. The key is then added via `sam-add` and tracked in the database with status `ACTIVE`.

For a deeper look at the technical design, see the [DESIGN.md](https://github.com/stephdl/ssh-access-manager/blob/main/DESIGN.md) of the upstream project.

**Stack**: Python 3.12 · Flask · PostgreSQL 18 · Nginx · Vue.js 3 · Supervisord · Alpine

## Install

Instantiate the module with:

```
add-module ghcr.io/stephdl/ssh-access-manager:latest 1
```

The output of the command will return the instance name:

```json
{"module_id": "ssh-access-manager1", "image_name": "ssh-access-manager", "image_url": "ghcr.io/stephdl/ssh-access-manager:latest"}
```

## Configure

Let's assume the instance is named `ssh-access-manager1`.

Launch `configure-module` with the following parameters:

| Parameter | Type | Required | Description |
|---|---|---|---|
| `host` | string | yes | FQDN for the application, e.g. `ssh-access-manager.domain.org` |
| `http2https` | boolean | no | Redirect HTTP to HTTPS (default: `true`) |
| `lets_encrypt` | boolean | no | Request a Let's Encrypt certificate (default: `false`) |
| `from` | string (email) | no | Sender address for email alerts (empty to disable) |
| `to` | string (email) | no | Recipient address for email alerts (empty to disable) |
| `ssh_user` | string | no | Unix user created on remote servers for auditing (default: `audit-collector`) |
| `scan_interval_hours` | string | no | Interval in hours between automatic scans (default: `4`) |
| `expire_warn_days` | string | no | Days before key expiry for the first warning (default: `7`) |
| `expire_warn_days_2` | string | no | Days before key expiry for the second warning (default: `2`) |
| `admin_username` | string | no | Initial administrator username (default: `admin`) |
| `admin_email` | string | no | Initial administrator email |
| `admin_password` | string | no | Initial administrator password |
| `tz` | string | no | Timezone (default: `UTC`) |

Example:

```
api-cli run configure-module --agent module/ssh-access-manager1 --data - <<EOF
{
  "host": "ssh-access-manager.domain.org",
  "http2https": true,
  "lets_encrypt": true,
  "from": "noreply@domain.org",
  "to": "admin@domain.org",
  "ssh_user": "audit-collector",
  "scan_interval_hours": "4",
  "expire_warn_days": "7",
  "expire_warn_days_2": "2",
  "admin_username": "admin",
  "admin_email": "admin@domain.org",
  "admin_password": "changeme",
  "tz": "Europe/Paris"
}
EOF
```

The above command will:
- generate secrets (`FLASK_SECRET_KEY`, `POSTGRES_PASSWORD`) on first run and persist them in `secrets.env`
- start and configure the ssh-access-manager instance
- configure a Traefik virtual host to expose the application

## Get the configuration

```
api-cli run get-configuration --agent module/ssh-access-manager1
```

## Provision a remote server

Both steps (preparing the remote host and registering it in the database) can be done with a single helper script. Enter the module environment first:

```bash
runagent -m ssh-access-manager1
```

Then use the `provision-server` script:

```bash
../bin/provision-server --hostname server-prod-01 --ip 192.168.1.100 --user root --env production --os rhel
```

Options:

| Option | Default | Description |
|---|---|---|
| `--hostname` | — | Server hostname (required) |
| `--ip` | — | Server IP address (required) |
| `--user` | `root` | SSH user to connect with |
| `--env` | `production` | Environment: `production`, `staging`, `development` |
| `--os` | `other` | OS family: `rhel`, `debian`, `ubuntu`, `alpine`, `other` |

The script:
1. Deploys the `audit-collector` user, SSH key, and sudoers rules on the target server (idempotent — safe to re-run after a rebuild or sudoers change).
2. Registers the server in the database.

The server can also be declared manually via the web UI: **Dashboard → + Add server**.

The collector public key is visible in the web UI at **Dashboard > Collector public key**.

## Workflow overview

1. **Provision** each remote server (see above).
2. **Declare** the server in the web UI (Dashboard → + Add server) or via the NS8 API.
3. **Scan** — at first scan, all existing `authorized_keys` are imported with status `PENDING_REVIEW` and a CRITICAL email alert is sent for each unknown key.
4. **Review** anomalies in the web UI (Anomalies tab): validate legitimate keys or revoke unwanted ones.
5. From that point, the module scans automatically every `scan_interval_hours` hours and alerts on any change detected outside the system.

## Smarthost setting discovery

Email alert settings (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`) are not part of `configure-module` input. They are discovered automatically from the NethServer 8 centralized [smarthost configuration](https://nethserver.github.io/ns8-core/core/smarthost/) each time the service starts via `bin/discover-smarthost`.

If the smarthost configuration changes while the module is running, the event handler `events/smarthost-changed/10reload_services` restarts the service automatically.

The `from` and `to` email addresses are set via `configure-module` and can be left empty to disable email alerts.

## Uninstall

```
remove-module --no-preserve ssh-access-manager1
```

## Testing

Test the module using the `test-module.sh` script:


    ./test-module.sh <NODE_ADDR> ghcr.io/nethserver/ssh-access-manager:latest

The tests are made using [Robot Framework](https://robotframework.org/)

## UI translation

Translated with [Weblate](https://hosted.weblate.org/projects/ns8/).

To setup the translation process:

- add [GitHub Weblate app](https://docs.weblate.org/en/latest/admin/continuous.html#github-setup) to your repository
- add your repository to [hosted.weblate.org]((https://hosted.weblate.org) or ask a NethServer developer to add it to ns8 Weblate project
