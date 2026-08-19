# Storiza provision scripts

The install scripts that run on a [Storiza](https://storiza.store) VPS the first time it
boots. Order a server with a template that is more than a plain operating system — a game
panel, a control panel, an application — and the script for it is fetched from this
repository and executed once, before the server is handed over.

They live in public for a simple reason: this code runs as root on a machine you paid for,
using answers you typed at checkout. You should be able to read it first.

Nothing here is Storiza-only. Each script is an ordinary `bash` installer that runs on a
fresh Ubuntu or Debian machine, and you are welcome to run one yourself.

## How a script is run

The VPS creation worker writes the order into the guest, then cloud-init fetches the
script and runs it once:

```bash
curl -fsSL <script url> -o /tmp/storiza-provision.sh
bash /tmp/storiza-provision.sh
rm -f /tmp/storiza-provision.sh /etc/storiza/provision.json
```

Both files are deleted afterwards, along with cloud-init's own copy of the user-data.

## The payload

Answers reach a script through a file — never as arguments, so nothing typed at checkout
can end up in a process list or a shell history:

```jsonc
// /etc/storiza/provision.json
{
  "vps": {
    "hostname": "panel-01",
    "ip": { "address": "203.0.113.7", "gateway": "203.0.113.1", "netmask": "24" }
    // ... the rest of the server record
  },
  "inputs": {
    // the answers to the fields the template declares, keyed by field name
    "admin_email": "you@example.com",
    "admin_password": "...",
    "panel_domain": "panel.example.com"
  }
}
```

Read it with `jq`, and treat every value as untrusted input:

```bash
answer() { jq -r "$1 // empty" /etc/storiza/provision.json; }

ADMIN_EMAIL=$(answer '.inputs.admin_email')
[ -n "$ADMIN_EMAIL" ] || { echo "admin_email is required"; exit 1; }
```

## Layout

One file per product, filed by what it is:

```
panels/
  gamepanels/     pterodactyl.sh, pelican.sh, ...
  webpanels/      cpanel.sh, cyberpanel.sh, aapanel.sh, ...
applications/
  automation/     n8n.sh, ...
  databases/      ...
  monitoring/     ...
```

The path is the contract: a template's `provisionScriptURL` points straight at the raw
file, so moving or renaming one breaks every future install of that template. Add a new
directory rather than bending an existing name.

## Writing one

- `#!/bin/bash` and `set -euo pipefail`. A half-installed server is worse than a failed
  install, and the customer can always reinstall.
- **Never interactive.** No prompts, no `read`, no pagers — nothing is attached to a
  terminal. Pass `-y`, `--non-interactive`, `DEBIAN_FRONTEND=noninteractive`.
- **Never print a secret** to stdout. It lands in `/var/log/cloud-init-output.log`, which
  is world-readable. Write credentials to a `chmod 600` file under `/root` instead.
- Fail loudly and early on a missing required input, before touching the system.
- Assume Ubuntu 20.04+ / Debian 11+ and nothing else installed. `jq` is available: every
  template that ships inputs lists it in `requiredPackages`.
- Log what you are doing. The customer can read the log while it runs.

## What is here

| Script | Installs |
|---|---|
| [`panels/gamepanels/pterodactyl.sh`](panels/gamepanels/pterodactyl.sh) | Pterodactyl Panel + Wings, first admin, node and allocations |

`tests/pterodactyl-payload-check.sh` runs that script's payload parsing against fixtures
without installing anything — `bash tests/pterodactyl-payload-check.sh` from the repository
root.

## Reporting a problem

Open an issue here for the scripts themselves. For anything about a server you ordered,
go through [Storiza support](https://storiza.store) — this repository has no access to
accounts, servers, or orders.
