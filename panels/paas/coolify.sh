#!/usr/bin/env bash
#
# Coolify -- Storiza provision script.
#
# Inputs consumed:
#     inputs.admin_email     -- becomes Coolify's root user, required
#     inputs.admin_password  -- its password, required
#     inputs.panel_domain    -- optional; becomes the dashboard's address
#
# HTTPS, and why nothing is put in front of Coolify:
#
# Coolify is served by its own Traefik on 80 and 443, and it must be. The
# dashboard is a Laravel application that builds every asset URL from the
# address it believes it lives at, so proxying it on another port gives you a
# page on :8443 asking for its stylesheets on :443, and a realtime socket
# dialling a port that answers in plaintext. The panel half-loads and nothing
# explains why.
#
# So all this script does is tell Coolify its own address, https and all, and
# leave the serving to the proxy that came with it. The certificate Traefik
# answers with is its own until the customer sets a domain and a certificate
# resolver from the Settings page, which is where upstream wants that done.
#
# Ports: 80 and 443, which are also what route the applications the customer
# deploys. 8000 -- the dashboard's own plaintext port, published by Docker --
# is closed to the internet, so there is no way in that is not TLS.
#
# Upstream: https://coolify.io  (Apache-2.0, coolLabs)
# Installer: https://cdn.coollabs.io/coolify/install.sh
set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/storizagroup/storiza-provision-scripts/main/lib/provision.sh \
	-o /tmp/storiza-lib.sh && . /tmp/storiza-lib.sh

storiza_start "Coolify" \
	"Reading your answers" \
	"Installing system dependencies" \
	"Installing Coolify" \
	"Setting the dashboard address" \
	"Closing the ports nothing should reach"

SOURCE_DIR=/data/coolify/source

step
ADMIN_EMAIL=$(need '.inputs.admin_email')
ADMIN_PASSWORD=$(need '.inputs.admin_password')
PANEL_DOMAIN=$(answer '.inputs.panel_domain')
IP_ADDRESS=$(answer '.vps.ip.address')
[ -n "$IP_ADDRESS" ] || IP_ADDRESS=$(curl -4 -s --max-time 5 https://api.ipify.org || true)
[ -n "$IP_ADDRESS" ] || IP_ADDRESS=$(hostname -I | awk '{print $1}')

PANEL_HOST="${PANEL_DOMAIN:-$IP_ADDRESS}"
[ -n "$PANEL_HOST" ] || fail "This server has no address to publish Coolify on."
PANEL_URL="https://${PANEL_HOST}"

step
pkg curl
# Ports 80 and 443 belong to Coolify's Traefik. Anything else holding them
# stops the installer, and a leftover nginx default site is the usual culprit.
systemctl disable --now nginx > /dev/null 2>&1 || true

step
echo "[storiza] running the Coolify installer -- this takes several minutes"
curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/coolify-install.sh
ROOT_USERNAME="admin" \
	ROOT_USER_EMAIL="$ADMIN_EMAIL" \
	ROOT_USER_PASSWORD="$ADMIN_PASSWORD" \
	bash /tmp/coolify-install.sh || fail "The Coolify installer did not finish."
rm -f /tmp/coolify-install.sh

step
# Coolify builds its own URLs from APP_URL. It has to agree with the address
# the browser actually used, or the dashboard asks for its assets on the wrong
# scheme -- which is the whole reason this script does not proxy it.
[ -f "$SOURCE_DIR/.env" ] || fail "Coolify installed without its environment file -- nothing to configure."
if grep -q '^APP_URL=' "$SOURCE_DIR/.env"; then
	sed -i "s|^APP_URL=.*|APP_URL=${PANEL_URL}|" "$SOURCE_DIR/.env"
else
	echo "APP_URL=${PANEL_URL}" >> "$SOURCE_DIR/.env"
fi

(cd "$SOURCE_DIR" && docker compose --env-file .env -f docker-compose.yml -f docker-compose.prod.yml up -d) \
	|| echo "[storiza] Coolify did not restart cleanly -- the dashboard may need a moment"

step
allow_ports 80/tcp 443/tcp
deny_ports 8000/tcp

credentials <<CREDS
# Coolify

| | |
|---|---|
| URL | ${PANEL_URL} |
| Email | ${ADMIN_EMAIL} |
| Password | ${ADMIN_PASSWORD} |

Coolify serves the dashboard through its own proxy on 443. Port 8000 is the
dashboard's plaintext port and is closed to the internet, so there is no way
in that is not encrypted.

Do give the dashboard a domain soon. Until it has one the connection is
encrypted but nothing vouches for the certificate, so the browser cannot tell
you whether the server answering is really yours. Point a domain at this
server, then set it along with a certificate resolver under Settings and
Coolify asks Let's Encrypt for a real one.

Ports 80 and 443 also route the applications you deploy. Everything else is
closed -- open what you need with \`ufw allow <port>\`.
CREDS

echo "[storiza] Coolify ready at ${PANEL_URL}"
