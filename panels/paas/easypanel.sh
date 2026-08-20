#!/usr/bin/env bash
#
# Easypanel -- Storiza provision script.
#
# Inputs consumed:
#     inputs.panel_domain    -- optional; see below
#
# Like Dokploy, Easypanel has no supported way to create the first account
# without a browser: the first visitor becomes the owner. The instructions say
# to register immediately.
#
# Why the dashboard is not put behind TLS here:
#
# Easypanel runs its own Traefik on 80 and 443 for the applications the
# customer deploys, and expects to serve its own dashboard through it once the
# panel has been told which domain it answers on. Putting another web server
# in front on a side port gives the panel an address it does not know about,
# and a dashboard that argues with itself about where it lives -- assets on
# the wrong port, sessions that will not stick.
#
# So the dashboard is left where Easypanel puts it, on 3000, and the customer
# sets a domain from inside the panel, which is one click and gets a real
# certificate from Easypanel's own proxy.
#
# Ports: 80 and 443 for the applications the customer deploys, and 3000 for
# the dashboard until it has a domain of its own.
#
# Upstream: https://easypanel.io
# Installer: https://get.easypanel.io
set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/storizagroup/storiza-provision-scripts/main/lib/provision.sh \
	-o /tmp/storiza-lib.sh && . /tmp/storiza-lib.sh

storiza_start "Easypanel" \
	"Reading your answers" \
	"Installing system dependencies" \
	"Installing Easypanel" \
	"Closing the ports nothing should reach"

step
PANEL_DOMAIN=$(answer '.inputs.panel_domain')
IP_ADDRESS=$(answer '.vps.ip.address')
[ -n "$IP_ADDRESS" ] || IP_ADDRESS=$(curl -4 -s --max-time 5 https://api.ipify.org || true)
[ -n "$IP_ADDRESS" ] || IP_ADDRESS=$(hostname -I | awk '{print $1}')
[ -n "$IP_ADDRESS" ] || fail "This server has no address to publish Easypanel on."

PANEL_URL="http://${IP_ADDRESS}:3000"

step
pkg curl lsof
# The installer checks 80 and 443 with lsof and exits if either is taken, so
# nothing of ours may be holding them when it runs.
systemctl disable --now nginx > /dev/null 2>&1 || true

step
echo "[storiza] running the Easypanel installer -- this takes several minutes"
curl -fsSL https://get.easypanel.io -o /tmp/easypanel-install.sh
sh /tmp/easypanel-install.sh || fail "The Easypanel installer did not finish."
rm -f /tmp/easypanel-install.sh

step
allow_ports 80/tcp 443/tcp 3000/tcp

credentials <<CREDS
# Easypanel

| | |
|---|---|
| URL | ${PANEL_URL} |
| Account | none yet -- the first visitor registers as the owner |

Open the URL and register now. Until you do, anyone who finds this server can
claim it.

## Then give it a domain

The dashboard is on plain HTTP until it has one, because Easypanel serves it
through its own proxy and only once it knows which domain to answer on. Point
${PANEL_DOMAIN:-a domain} at ${IP_ADDRESS}, then set it in Easypanel's
settings: its proxy asks Let's Encrypt for a certificate and the panel moves
to 443.

Until then, treat that first login as one you are making on an untrusted
network: it is not encrypted.

Ports 80 and 443 route the applications you deploy. Everything else is closed
-- open what you need with \`ufw allow <port>\`.
CREDS

echo "[storiza] Easypanel ready at ${PANEL_URL} -- register the owner account now"
