#!/usr/bin/env bash
#
# Dokploy -- Storiza provision script.
#
# Inputs consumed:
#     inputs.panel_domain    -- optional; see below
#
# Dokploy has no supported way to create its first account without a browser:
# whoever opens the dashboard first registers as the owner. There is nothing
# to pre-seed, so this script does not pretend to -- it installs Dokploy and
# the instructions tell the customer to register immediately.
#
# Why the dashboard is not put behind TLS here:
#
# Dokploy authenticates with better-auth, which refuses any request whose
# Origin is not on a list it keeps in its own database. Serving the panel from
# anywhere other than the address it knows about answers every login with
# "Invalid Origin", and no proxy header can talk it round -- an allowlist is
# not a header check. That list is written by the Settings -> Web Server page,
# which also asks Dokploy's own Traefik for a Let's Encrypt certificate.
#
# So the dashboard is left where Dokploy puts it, on 3000, and the customer
# gives it a domain from inside the panel. It is one click and it is the only
# path that ends with both HTTPS and a working login.
#
# Ports: 80 and 443 for the applications the customer deploys, and 3000 for
# the dashboard until it has a domain of its own.
#
# Upstream: https://dokploy.com  (Apache-2.0)
# Installer: https://dokploy.com/install.sh
set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/storizagroup/storiza-provision-scripts/main/lib/provision.sh \
	-o /tmp/storiza-lib.sh && . /tmp/storiza-lib.sh

storiza_start "Dokploy" \
	"Reading your answers" \
	"Installing system dependencies" \
	"Installing Dokploy" \
	"Closing the ports nothing should reach"

step
PANEL_DOMAIN=$(answer '.inputs.panel_domain')
IP_ADDRESS=$(answer '.vps.ip.address')
[ -n "$IP_ADDRESS" ] || IP_ADDRESS=$(curl -4 -s --max-time 5 https://api.ipify.org || true)
[ -n "$IP_ADDRESS" ] || IP_ADDRESS=$(hostname -I | awk '{print $1}')
[ -n "$IP_ADDRESS" ] || fail "This server has no address to publish Dokploy on."

PANEL_URL="http://${IP_ADDRESS}:3000"

step
pkg curl
# Dokploy's Traefik takes 80 and 443, and the installer stops if anything else
# holds them. A leftover nginx default site is the usual culprit.
systemctl disable --now nginx > /dev/null 2>&1 || true

step
echo "[storiza] running the Dokploy installer -- this takes several minutes"
curl -fsSL https://dokploy.com/install.sh -o /tmp/dokploy-install.sh
sh /tmp/dokploy-install.sh || fail "The Dokploy installer did not finish."
rm -f /tmp/dokploy-install.sh

step
allow_ports 80/tcp 443/tcp 3000/tcp

credentials <<CREDS
# Dokploy

| | |
|---|---|
| URL | ${PANEL_URL} |
| Account | none yet -- the first visitor registers as the owner |

Open the URL and register now. Until you do, anyone who finds this server can
claim it.

## Then give it a domain

The dashboard is on plain HTTP until it has one, because Dokploy only trusts
logins coming from an address it knows about, and that address is set from
inside the panel. Point ${PANEL_DOMAIN:-a domain} at ${IP_ADDRESS}, then open
Settings -> Web Server, set the domain and enable HTTPS. Dokploy adds it to
its trusted origins and asks Let's Encrypt for a certificate, and the panel
moves to 443.

Until then, treat that first login as one you are making on an untrusted
network: it is not encrypted.

Ports 80 and 443 route the applications you deploy. Everything else is closed
-- open what you need with \`ufw allow <port>\`.
CREDS

echo "[storiza] Dokploy ready at ${PANEL_URL} -- register the owner account now"
