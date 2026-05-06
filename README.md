# sam

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
add-module ghcr.io/stephdl/sam:latest 1
```

The output of the command will return the instance name:

```json
{"module_id": "sam1", "image_name": "sam", "image_url": "ghcr.io/stephdl/sam:latest"}
```

## Configure

Let's assume the instance is named `sam1`.

Launch `configure-module` with the following parameters:

| Parameter | Type | Required | Description |
|---|---|---|---|
| `host` | string | yes | FQDN for the application, e.g. `sam.domain.org` |
| `http2https` | boolean | no | Redirect HTTP to HTTPS (default: `true`) |
| `lets_encrypt` | boolean | no | Request a Let's Encrypt certificate (default: `false`) |
| `ssh_user` | string | no | Unix user created on remote servers for auditing (default: `audit-collector`) |

Example:

```
api-cli run configure-module --agent module/sam1 --data - <<EOF
{
  "host": "sam.domain.org",
  "http2https": true,
  "lets_encrypt": true,
  "ssh_user": "audit-collector",
}
EOF
```

The above command will:
- generate secrets (`FLASK_SECRET_KEY`, `POSTGRES_PASSWORD`) on first run and persist them in `secrets.env`
- start and configure the sam instance
- configure a Traefik virtual host to expose the application

## Get the configuration

```
api-cli run get-configuration --agent module/sam1
```

## Provision a remote server

> **Prerequisites**: `sudo` must be installed and available on the remote server. The provisioning script configures a `sudo` delegation for `audit-collector` — without `sudo`, the setup will fail and SAM will be unable to collect SSH keys or perform any action on that server.

Provisioning a server has two distinct phases:

1. **Host preparation** — create the `audit-collector` Unix user, deploy the SAM scripts, and configure the `sudo` delegation on the remote server.
2. **Database registration** — declare the server in SAM so it can be scanned.

The main difference between the four methods below is **how you authenticate** for the host-preparation step. Choose the one that matches your security policy.

### Overview

| Method | Authentication | Root password given to SAM? | Requires NS8 CLI? |
|---|---|---|---|
| [1. SAM UI](#method-1--sam-web-ui-easiest) | root password in the web form | ✅ Yes | No |
| [2. `provision-server` (interactive)](#method-2--provision-server-interactive-password) | root password via OpenSSH | No — transits through OpenSSH only | Yes |
| [3. `ssh-copy-id` + `provision-server --use-container-key`](#method-3--ssh-copy-id--provision-server-paranoid) | key-based (collector key) | ⚠️ Once (for `ssh-copy-id` only) | Yes |
| [4. Fully manual](#method-4--manual-key-placement--provision-server-maximum-control) | manual key placement (any access method) | ❌ Never | Yes |

---

### Method 1 — SAM web UI (easiest)

Open the SAM web UI, go to **Dashboard → + Add server**, and fill in the hostname, IP address, and root credentials. SAM connects as root, runs the provisioning script, and registers the server automatically.

**When to use**: quick setup on a trusted, private network where transmitting the root password over HTTPS is acceptable.

> ⚠️ The root password is sent through the SAM web form. Make sure HTTPS is enabled (`lets_encrypt: true` or a valid certificate).

---

### Method 2 — `provision-server` interactive password

Run the helper script from the NS8 host. The script calls the standard OpenSSH client (`ssh`) from the NS8 node, which follows normal SSH authentication order:

1. **Key-based first** — if the NS8 module user (`sam1`) already has an SSH key pair and its public key is present in `root@remote:~/.ssh/authorized_keys`, the connection succeeds **with no password prompt at all**.
2. **Password fallback** — if no key is found or accepted, OpenSSH prompts for the root password directly in your terminal. The password transits through OpenSSH only — it is never seen, stored, or logged by SAM.

```bash
runagent -m sam1
../bin/provision-server --hostname server-prod-01 --ip 192.168.1.100 --user root --env production --os rhel
```

With a non-standard SSH port:

```bash
../bin/provision-server --hostname server-prod-01 --ip 192.168.1.100 --port 2222 --user root --env production --os rhel
```

Options:

| Option | Default | Description |
|---|---|---|
| `--hostname` | — | Server hostname (required) |
| `--ip` | — | Server IP address (required) |
| `--user` | `root` | SSH user to connect with |
| `--port` | `22` | SSH port on the remote server |
| `--env` | `production` | Environment: `production`, `staging`, `development` |
| `--os` | `other` | OS family: `rhel`, `debian`, `ubuntu`, `alpine`, `other` |
| `--use-container-key` | — | Use the collector private key (see Method 3) |

**When to use**: the root password is typed directly in the terminal, never seen by SAM. Good default for most environments.

---

### Method 3 — `ssh-copy-id` + `provision-server` (paranoid)

This method ensures the root password is **never given to SAM**, not even indirectly. You push the SAM collector's public key to the remote server yourself (in your terminal), and then let `provision-server` connect using that key.

#### Step 1 — Prepare the container's SSH directory (once per NS8 node)

The container's `~/.ssh` directory may not exist by default. Create it once:

```bash
runagent -m sam1
podman exec sam-app mkdir -p /root/.ssh
```

#### Step 2 — Push the collector public key to the remote server

```bash
podman exec -it -e TMPDIR=/tmp sam-app \
    ssh-copy-id -i /data/keys/collector_key.pub -p 22 root@192.168.1.100
```

`ssh-copy-id` will ask for the root password **once**, directly in your terminal (not through SAM). After this, the container can authenticate to that server as root without a password.

For a non-standard SSH port (e.g. 2222):

```bash
podman exec -it -e TMPDIR=/tmp sam-app \
    ssh-copy-id -i /data/keys/collector_key.pub -p 2222 root@192.168.1.140
```

> **Note**: the `-e TMPDIR=/tmp` flag is required because the container's default `TMPDIR` may be unset or point to a non-existent path, which causes `ssh-copy-id` to fail with `mktemp: : No such file or directory`. You may also see harmless warnings like `expr: syntax error` or `expr: warning: '^ERROR:'` — these are cosmetic bugs in the `ssh-copy-id` script itself and do not affect the result.

#### Step 3 — Provision using the container key (no password)

Standard port:

```bash
../bin/provision-server --hostname server-prod-01 --ip 192.168.1.100 --user root --env production --os rhel --use-container-key
```

Non-standard port:

```bash
../bin/provision-server --hostname server-prod-01 --ip 192.168.1.140 --port 2222 --user root --env production --os rhel --use-container-key
```

The `--use-container-key` flag makes `provision-server` run the SSH connection from **inside the container**, using the collector's private key at `/data/keys/collector_key`. No password prompt, SAM never handles root credentials.

**When to use**: security-conscious environments. The root password is entered once in a terminal for `ssh-copy-id`, then never required again. SAM only ever uses its own key.

> 💡 After provisioning, you can revoke root access for the collector key if you wish — `audit-collector` is the only user SAM will ever use for day-to-day operations.

---

### Method 4 — Manual key placement + `provision-server` (maximum control)

Same principle as Method 3 but without `ssh-copy-id`: you place the collector public key in root's `authorized_keys` yourself, using whatever access you already have (console, existing SSH session, Ansible, configuration management…). SAM's root password is never involved at any point.

#### Step 1 — Retrieve the collector public key

```bash
runagent -m sam1
podman exec sam-app cat /data/keys/collector_key.pub
```

Copy the output (a single line starting with `ssh-ed25519 ...`).

#### Step 2 — Add the key to the remote server manually

Connect to the remote server by any means available to you (console, bastion, existing privileged account), then append the key:

```bash
# On the remote server, as root:
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "ssh-ed25519 AAAA... paste-your-collector-key-here" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

#### Step 3 — Provision using the container key (no password)

Back on the NS8 host, inside the module environment:

```bash
runagent -m sam1
../bin/provision-server --hostname server-prod-01 --ip 192.168.1.100 --user root --env production --os rhel --use-container-key
```

`provision-server` connects as root using the collector private key (no password prompt), runs `provision-host.sh` on the remote server (creates the `audit-collector` user, deploys the SAM scripts, configures sudoers), and registers the server in the database.

**When to use**: environments where `podman exec` is not available interactively, or where you prefer to place keys through a controlled channel (Ansible, Puppet, a jump host) rather than running `ssh-copy-id` from the NS8 node.

---

### Which method should I choose?

```
Comfortable typing root password in a web form?
  └─ Yes → Method 1 (UI)
  └─ No  → Comfortable typing it in a terminal?
              └─ Yes → Method 2 (provision-server, interactive)
              └─ No  → Can you run podman exec on the NS8 node?
                          └─ Yes → Method 3 (ssh-copy-id + --use-container-key)
                          └─ No  → Method 4 (place key manually + --use-container-key)
```

The collector public key is visible in the web UI at **Dashboard > Collector public key**.

---

### Monitoring the NS8 host itself

> **Important**: if you want SAM to monitor the NS8 node it runs on, always declare port **22** for that server — **not** any custom port configured for external SSH access.

NS8 recommends redirecting external SSH traffic from a non-standard port (e.g. 2222) to port 22 using a firewalld port forward — see [NS8 firewall documentation — SSH redirection](https://docs.nethserver.org/projects/ns8/en/latest/firewall.html#ssh-redirection). This redirection only applies to traffic arriving on **external interfaces**. Connections originating from the same host (loopback or internal network) bypass the rule entirely: `sshd` is always reachable directly on port **22** locally.

If you declare port 2222 when adding the NS8 node itself to SAM, the connection will fail because the forward does not apply to local traffic.

Example — provisioning the NS8 host itself:

```bash
runagent -m sam1
../bin/provision-server --hostname ns8-node --ip 127.0.0.1 --port 22 --user root --env production --os rhel
```

The same applies when registering the server through the web UI: enter **22** in the port field regardless of which port is exposed externally.

## Workflow overview

1. **Provision** each remote server (see above).
2. **Declare** the server in the web UI (Dashboard → + Add server) or via the NS8 API.
3. **Scan** — at first scan, all existing `authorized_keys` are imported with status `PENDING_REVIEW` and a CRITICAL email alert is sent for each unknown key.
4. **Review** anomalies in the web UI (Anomalies tab): validate legitimate keys or revoke unwanted ones.
5. From that point, the module scans automatically every `scan_interval_hours` hours and alerts on any change detected outside the system.

## Granting admin privileges to a deployed user

SAM can create a Unix user on a remote server and push an SSH key to it (via the **Access → Deploy SSH key** form). However, **SAM does not grant any elevated privileges** to that user — it creates a normal unprivileged account. Granting sudo or administrative rights is a deliberate manual step that must be performed by a system administrator.

### Why is this manual?

Automatically granting `root`-equivalent privileges would bypass the principle of least privilege that SAM is designed to enforce. The decision to give a user admin rights on a server must remain under explicit human control.

### Option 1 — Full sudo access (not recommended for most users)

Connect to the target server as root or with an existing sudo account, then add the user to the privileged group:

```bash
# Debian / Ubuntu
usermod -aG sudo alice

# RHEL / Rocky / CentOS / AlmaLinux
usermod -aG wheel alice
```

The user can then run any command with `sudo`. This is equivalent to unrestricted root delegation — use only for trusted administrators.

### Option 2 — Fine-grained sudoers delegation (recommended)

For a more controlled approach, create a dedicated sudoers file that grants only the commands the user actually needs:

```bash
# Connect to the target server, then:
cat > /etc/sudoers.d/alice <<'EOF'
# Allow alice to restart specific services only (password required)
alice ALL= /usr/bin/systemctl restart nginx
alice ALL= /usr/bin/systemctl restart myapp

# Allow alice to read logs (password required)
alice ALL= /usr/bin/journalctl -u nginx *
EOF

chmod 440 /etc/sudoers.d/alice

# Validate the file before logging out
visudo -c -f /etc/sudoers.d/alice
```

> **Always validate with `visudo -c`** before closing your session. A syntax error in a sudoers file can lock out all sudo access on the server.

> **`NOPASSWD` — when to use it**: omitting `NOPASSWD` (as above) means `alice` will be prompted for **her own password** each time she runs `sudo`. This is the correct behaviour for a human account. `NOPASSWD` is reserved for **non-interactive service accounts** like `audit-collector`, where a script must run unattended without a terminal to enter a password.

### Option 3 — Delegating access to another admin's sudoers rules

If the target user only needs to run the same commands as an existing role, you can include a shared sudoers snippet:

```bash
cat > /etc/sudoers.d/ops-team <<'EOF'
# Shared rules for the ops team (password required)
%ops ALL= /usr/bin/systemctl restart *
%ops ALL= /usr/bin/journalctl *
EOF

# Add the user to the ops group
usermod -aG ops alice
```

### Summary

| What SAM does automatically | What requires manual action |
|---|---|
| Creates the Unix user on the remote server | Adding the user to `sudo` or `wheel` group |
| Pushes the SSH public key to `authorized_keys` | Creating a sudoers delegation file |
| Tracks the key lifecycle (expiry, revocation) | Deciding which commands the user may run as root |
| Locks/unlocks the Unix account | Removing the user from privileged groups |

## Default credentials

After the first `configure-module`, the web UI is accessible with the following default credentials:

| Username | Password |
|---|---|
| `admin` | `admin` |

> **Change the password immediately** after the first login. The default `admin`/`admin` credentials are well-known and must not be left in place on any production instance. Use the web UI (profile menu → Change password) or the `reset-password` script below.

### Resetting a SAM administrator password from the CLI

Works for any SAM administrator account (web UI login), regardless of their role. This has no effect on Linux accounts on remote servers. Enter the module environment first:

```bash
runagent -m sam1
```

Then use the `reset-password` script:

```bash
../bin/reset-password --username admin --password NewStr0ng#Pass!
```

| Option | Description |
|---|---|
| `--username` | Username to reset (required) |
| `--password` | New password (required) |

> Password policy: at least 8 characters, one uppercase letter, one digit, one special character. Works even if the account is disabled. The operation is recorded in the audit log (`PASSWORD_RESET`).

## Roles and permissions

Three roles are available for SAM administrators:

| Role | Rights |
|---|---|
| `sysadmin` | Full access: manage administrators, servers, SSH keys, access, and system configuration |
| `operator` | SSH actions: validate, revoke, deploy keys, lock/unlock Unix accounts, trigger scans |
| `viewer` | Read-only: browse all views without any write action |

Roles are enforced **server-side** (Flask returns 403 for unauthorized requests) and **client-side** (buttons and forms are hidden according to the role).

A `sysadmin` cannot modify their own role. An email address is required when creating an account.

### Permissions by category

| Category | sysadmin | operator | viewer |
|---|---|---|---|
| Read (GET — all resources) | ✓ | ✓ | ✓ |
| SSH actions (validate/revoke keys, scans, deploy, lock/unlock) | ✓ | ✓ | ✗ |
| System administration (servers, admins, configuration) | ✓ | ✗ | ✗ |
| Change own password | ✓ | ✓ | ✓ |

### Managing administrators via CLI

Enter the module environment first:

```bash
runagent -m sam1
```

Then use `manage.py` through the container:

```bash
# List all administrators
podman exec sam-app python3 /app/app/manage.py admin list

# Create a new administrator (default role: operator)
podman exec sam-app python3 /app/app/manage.py admin add \
  --username alice --email alice@example.com --password SECRET --role operator

# Promote to sysadmin
podman exec sam-app python3 /app/app/manage.py admin update alice --role sysadmin

# Demote to viewer
podman exec sam-app python3 /app/app/manage.py admin update alice --role viewer

# Disable / re-enable an account
podman exec sam-app python3 /app/app/manage.py admin disable alice
podman exec sam-app python3 /app/app/manage.py admin enable alice
```

## Key lifecycle

After the first scan, all discovered keys are in `PENDING_REVIEW` status. The following actions are available on each key from the web UI (server detail view) or CLI:

| Action | Web UI | Effect |
|---|---|---|
| **Validate** | Anomalies tab | Marks the key as `ACTIVE` — legitimate key |
| **Revoke** | Server detail | Removes the key from `authorized_keys` on the remote server immediately — reason required |
| **Assign** | Server detail | Associates the key with an administrator (shown in the Owner column) |
| **Set expiry** | Server detail | Sets a date/time or a duration in hours — key is automatically revoked at expiry |
| **Remove expiry** | Server detail | Clears expiration (only visible if `expires_at` is set) |

Two warning emails are sent before expiry: at `expire_warn_days` days (default: 7) and `expire_warn_days_2` days (default: 2). Both thresholds are configurable without restart from **Settings → Expiry warnings**.

Key conformity is checked against ANSSI recommendations: `ssh-ed25519` is always compliant; `ssh-rsa` requires ≥ 4096 bits. Non-compliant keys are flagged with a ⚠️ badge — hover to see the reason.

### Key actions via CLI

```bash
# List keys pending review
podman exec sam-app python3 /app/app/manage.py keys list --status PENDING_REVIEW

# Validate a key
podman exec sam-app python3 /app/app/manage.py keys validate SHA256:...

# Revoke a key with a reason
podman exec sam-app python3 /app/app/manage.py keys revoke SHA256:... --reason "Orphan key"

# Assign a key to an owner
podman exec sam-app python3 /app/app/manage.py keys assign SHA256:... --owner "Alice Martin"

# Set expiry (duration or date)
podman exec sam-app python3 /app/app/manage.py keys set-expiry SHA256:... --hours 24
podman exec sam-app python3 /app/app/manage.py keys set-expiry SHA256:... --date "2026-12-31 23:59"

# Remove expiry
podman exec sam-app python3 /app/app/manage.py keys remove-expiry SHA256:...
```

## Locking and unlocking a Unix account

Revoking a key removes it from `authorized_keys` but leaves the Unix account active on the server. If the user still has another valid key, they can still connect. To block **all** SSH access for a given user:

**Via the web UI**: Access tab → **Lock / Unlock a Unix account** section.

| Action | Remote command | Effect |
|---|---|---|
| **Lock** | `usermod -L -s /sbin/nologin <user>` | Disables the password and blocks the shell — SSH connection impossible even with a valid key |
| **Unlock** | `usermod -U -s /bin/bash <user>` | Restores the account — SSH connection possible again with a valid key |

**Via CLI**:

```bash
podman exec sam-app python3 /app/app/manage.py access lock-user \
  --user alice --server server-prod-01

podman exec sam-app python3 /app/app/manage.py access unlock-user \
  --user alice --server server-prod-01
```

## Out-of-band revocation detection

If a scan detects that an `ACTIVE` key has disappeared from `authorized_keys` without any action recorded in the system (e.g. a direct `root` edit, a compromised account, or manual deletion):

1. The key is moved to `REVOKED` status with `revoked_automatically = true` and `revoked_by = NULL`
2. An `ANOMALY_DETECTED` entry is created in the audit log
3. A **CRITICAL email alert** is sent immediately
4. The key appears in **Anomalies → Out-of-band revocations**

Similarly, if a previously revoked or expired key **reappears** on a server (e.g. via `ssh-copy-id` after revocation), it is detected at the next scan and also triggers a CRITICAL alert.

Recommended action: investigate the origin of the deletion or reappearance (direct root access? compromised account?).

## Brute-force protection

SAM includes built-in protection against repeated login attempts. After N consecutive failed logins from the same IP address, that IP is temporarily banned.

- **Attempt limit**: configurable via `login_max_attempts` (default: 10)
- **Ban duration**: configurable via `login_ban_seconds` (default: 300 seconds)
- **HTTP response**: `429 Too Many Requests` during the ban
- **No restart needed**: changes take effect immediately from **Settings → Security** (requires `sysadmin` role)

### fail2ban / CrowdSec integration

Each failed login attempt and each ban is logged to stdout in a structured format:

```
[LOGIN_FAILED] ip=1.2.3.4 username=admin
[LOGIN_BANNED] ip=1.2.3.4 username=admin ban_seconds=300
```

These logs are visible via `podman logs sam-app` and can be consumed by fail2ban or CrowdSec to apply firewall-level bans. Example fail2ban filter:

```ini
# /etc/fail2ban/filter.d/sam.conf
[Definition]
failregex = \[LOGIN_FAILED\] ip=<HOST>
```

```ini
# /etc/fail2ban/jail.d/sam.conf
[sam]
enabled  = true
filter   = sam
backend  = systemd
journalmatch = CONTAINER_NAME=sam-app
maxretry = 5
bantime  = 3600
```

## CLI reference (NS8)

All `manage.py` commands must be run inside the module container. Enter the module environment first with `runagent -m sam1`, then use `podman exec sam-app`:

```bash
# Shortcut alias (optional, for the current shell session)
EXEC="podman exec sam-app python3 /app/app/manage.py"

# Servers
$EXEC servers list
$EXEC servers add --hostname HOST --ip IP --env production --os rhel
$EXEC servers scan
$EXEC servers scan --server HOST
$EXEC servers disable HOST
$EXEC servers enable HOST
$EXEC servers show HOST

# Keys
$EXEC keys list --status PENDING_REVIEW
$EXEC keys show SHA256:...
$EXEC keys search QUERY
$EXEC keys validate SHA256:...
$EXEC keys revoke SHA256:... --reason "Reason"
$EXEC keys assign SHA256:... --owner "Alice Martin"
$EXEC keys set-expiry SHA256:... --hours 24
$EXEC keys set-expiry SHA256:... --date "2026-12-31 23:59"
$EXEC keys remove-expiry SHA256:...

# Access
$EXEC access list
$EXEC access lock-user --user USER --server HOST
$EXEC access unlock-user --user USER --server HOST

# Administrators
$EXEC admin list
$EXEC admin add --username USER --email EMAIL --password PASSWORD [--role ROLE]
# ROLE: sysadmin | operator (default) | viewer
$EXEC admin update USERNAME [--email EMAIL] [--role ROLE]
$EXEC admin disable USERNAME
$EXEC admin enable USERNAME
$EXEC admin delete USERNAME
$EXEC admin reset-password USERNAME --password NEW_PASSWORD

# Audit
$EXEC audit list --action ANOMALY_DETECTED --since 2025-01-01
$EXEC audit list --server HOST

# System
$EXEC system status
$EXEC system report
```

## Smarthost setting discovery

> **Prerequisite**: SAM relies entirely on the NethServer 8 centralized smarthost to send email alerts. **If no smarthost is configured on your NS8 instance, SAM will not send any emails** (PENDING_REVIEW alerts, anomaly notifications, expiry warnings). Configure the smarthost first in the NS8 admin panel under **Settings → Smarthost** before expecting email delivery from SAM.

Email alert settings (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`) are not part of `configure-module` input. They are discovered automatically from the NethServer 8 centralized [smarthost configuration](https://nethserver.github.io/ns8-core/core/smarthost/) each time the service starts via `bin/discover-smarthost`.

If the smarthost configuration changes while the module is running, the event handler `events/smarthost-changed/10reload_services` restarts the service automatically.

The `from` and `to` email addresses are set via `configure-module` and can be left empty to disable email alerts.

## Uninstall

```
remove-module --no-preserve sam1
```

## Testing

Test the module using the `test-module.sh` script:


    ./test-module.sh <NODE_ADDR> ghcr.io/nethserver/sam:latest

The tests are made using [Robot Framework](https://robotframework.org/)

## UI translation

Translated with [Weblate](https://hosted.weblate.org/projects/ns8/).

To setup the translation process:

- add [GitHub Weblate app](https://docs.weblate.org/en/latest/admin/continuous.html#github-setup) to your repository
- add your repository to [hosted.weblate.org]((https://hosted.weblate.org) or ask a NethServer developer to add it to ns8 Weblate project
