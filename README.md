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
rm -f /tmp/storiza-provision.sh /var/lib/storiza/provision.json
```

The payload is deleted afterwards, along with cloud-init's own copy of the user-data.

## The payload

Answers reach a script through a file — never as arguments, so nothing typed at checkout
can end up in a process list or a shell history:

```jsonc
// /var/lib/storiza/provision.json
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

## Progress, while it installs

A script reports what it is doing into `/var/lib/storiza`, and Storiza reads those files
over the QEMU guest agent while the install runs — so the dashboard shows real progress
and a real failure reason instead of a spinner.

| File | Written | Contents |
|---|---|---|
| `steps` | once, before anything is installed | `[{"id":1,"name":"Installing system dependencies"}, …]` |
| `state` | at every step, atomically | `{"state":"running","current_step":3,"failure_reason":null}` |
| `logs` | continuously | everything the script printed, stdout and stderr both |

`state` is one of `waiting`, `running`, `completed` or `failed`. `waiting` is written by
Storiza before the machine boots; a script only moves it forward, and always reaches a
terminal value — the library's `EXIT` trap sees to that, so an install that dies on line
200 reports `failed` with the step that died, rather than sitting on `running` forever.

## Writing one

Source the library and declare your steps. That is the whole framework:

```bash
#!/usr/bin/env bash
set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/storizagroup/storiza-provision-scripts/main/lib/provision.sh \
	-o /tmp/storiza-lib.sh && . /tmp/storiza-lib.sh

storiza_start "Coolify" \
	"Reading your answers" \
	"Installing system dependencies" \
	"Installing Coolify" \
	"Publishing the dashboard over HTTPS"

step
ADMIN_EMAIL=$(need '.inputs.admin_email')
PANEL_DOMAIN=$(answer '.inputs.panel_domain')

step
pkg curl nginx openssl
…
```

[`lib/provision.sh`](lib/provision.sh) carries everything the installers share:

| | |
|---|---|
| `storiza_start "Name" "step"…` | writes `steps`, opens `logs`, arms the failure trap |
| `step` | advances `state` and prints `(3/5) Installing Coolify`. Takes no argument — the order lives in the list and nowhere else |
| `fail "…"` | stops, with a reason written for the customer to read |
| `answer` / `need` | read the payload; `need` stops when a required answer is missing |
| `pkg` | apt, quiet and non-interactive, updating the lists once per run |
| `supported_ubuntu 22.04 24.04` | stop early rather than half-install where the vendor will refuse |
| `self_signed` / `certbot_try` | a certificate for an IP or a name, upgraded to Let's Encrypt where the DNS already points here |
| `serve_https 23333` | both of those plus an nginx vhost in front of a local port. Not for a product that ships its own reverse proxy -- see below |
| `allow_ports` / `deny_ports` | see below |
| `credentials <<EOF` | writes `/root/<product>-credentials.md`, chmod 600 |

Beyond that:

- **Never interactive.** No prompts, no `read`, no pagers — nothing is attached to a
  terminal. Pass `-y`, `--non-interactive`, `DEBIAN_FRONTEND=noninteractive`.
- **Never print a secret** to stdout. It lands in `/var/log/cloud-init-output.log`, which
  is world-readable. Use `credentials` instead.
- Fail loudly and early on a missing required input, before touching the system.
- Assume Ubuntu 20.04+ / Debian 11+ and nothing else installed.
- Write step names and failure reasons for the customer. They end up in the dashboard.

## Ports

Two functions, and a script uses whichever fits — sometimes both:

```bash
allow_ports 80/tcp 443/tcp 8443/tcp   # refuse everything else
deny_ports  8000/tcp                  # close these, leave the rest alone
```

`allow_ports` suits a product with a short, known port list. `deny_ports` suits one whose
customer will be opening ports of their own — game servers, mail — where an allow list
would only get in the way. SSH always stays open.

Both together is normal, and on a Docker host it is the only thing that works: Docker's
DNAT rules run before ufw's filter chain, so a published container port ignores the allow
list completely. `deny_ports` writes the `DOCKER-USER` rule that actually closes it, into
ufw's `after.rules` so it survives a reboot. Rules are scoped to the interface the default
route leaves by, so a container reaching the host's database over the bridge still can.

## Layout

One file per product, filed by what it is:

```
lib/provision.sh   the shared library, fetched by every script at run time
panels/
  gamepanels/      pterodactyl.sh, mcsmanager.sh, ...
  webpanels/       cloudpanel.sh, cyberpanel.sh, cpanel.sh, ...
  paas/            coolify.sh, dokploy.sh, easypanel.sh, ...
applications/
  cms/             wordpress.sh, ...
_archive/          superseded scripts, kept for reference, never fetched
```

The path is the contract: a template's `provisionScriptURL` points straight at the raw
file, so moving or renaming one breaks every future install of that template. Add a new
directory rather than bending an existing name.

## What is here

| Script | Installs | Panel reachable at |
|---|---|---|
| [`panels/gamepanels/pterodactyl.sh`](panels/gamepanels/pterodactyl.sh) | Pterodactyl Panel + Wings, first admin, node, allocations, community eggs | `443` |
| [`panels/gamepanels/mcsmanager.sh`](panels/gamepanels/mcsmanager.sh) | MCSManager + Java 21, behind nginx | `443` |
| [`panels/webpanels/cloudpanel.sh`](panels/webpanels/cloudpanel.sh) | CloudPanel, admin account created via `clpctl` | `8443` |
| [`panels/webpanels/cyberpanel.sh`](panels/webpanels/cyberpanel.sh) | CyberPanel (OpenLiteSpeed), silent install | `8090` |
| [`panels/webpanels/cpanel.sh`](panels/webpanels/cpanel.sh) | cPanel & WHM — **licence required, not included** | `2087` |
| [`panels/paas/coolify.sh`](panels/paas/coolify.sh) | Coolify, root user seeded from the payload, dashboard address registered | `443` |
| [`panels/paas/dokploy.sh`](panels/paas/dokploy.sh) | Dokploy | `3000`, then `443` once it has a domain |
| [`panels/paas/easypanel.sh`](panels/paas/easypanel.sh) | Easypanel | `3000`, then `443` once it has a domain |
| [`applications/cms/wordpress.sh`](applications/cms/wordpress.sh) | WordPress on NGINX + PHP-FPM + MariaDB, install completed | `443` |

Every one of them serves its panel over HTTPS: Let's Encrypt where a domain was answered
and the panel does not manage its own certificates, self-signed otherwise. Panels that
already ship their own TLS (CloudPanel, CyberPanel, cPanel) keep theirs.

A note on the three PaaS panels. Coolify, Dokploy and Easypanel each ship their own
reverse proxy on 80 and 443 to serve the applications you deploy, and each decides what
its own address is and then checks requests against it -- asset URLs built from it, an
Origin allowlist keyed to it. Serving one of them from anywhere else gives you a panel
that argues with itself, so these scripts configure the panel's own address rather than
putting nginx in front of it. Coolify's is registered during the install and its
dashboard comes up on 443; Dokploy and Easypanel keep theirs on 3000 until the customer
sets a domain from inside the panel, which is the only thing that gets them onto 443 with
a certificate and a login that works.

## Tests

`bash tests/provision-protocol-check.sh` from the repository root. It exercises the
library against a throwaway directory — every way a script can end, the firewall rules a
deny list generates, and that each script declares as many steps as it takes. It installs
nothing.

## Reporting a problem

Open an issue here for the scripts themselves. For anything about a server you ordered,
go through [Storiza support](https://storiza.store) — this repository has no access to
accounts, servers, or orders.
