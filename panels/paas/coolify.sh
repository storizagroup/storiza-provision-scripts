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
[ -f "$SOURCE_DIR/.env" ] || fail "Coolify installed without its environment file -- nothing to configure."

# Coolify builds its own URLs from APP_URL, so it has to agree with the
# address the browser actually used.
if grep -q '^APP_URL=' "$SOURCE_DIR/.env"; then
	sed -i "s|^APP_URL=.*|APP_URL=${PANEL_URL}|" "$SOURCE_DIR/.env"
else
	echo "APP_URL=${PANEL_URL}" >> "$SOURCE_DIR/.env"
fi

# Coolify routes its own dashboard through its Traefik only when the instance
# has an FQDN, and that lives in its database -- the Settings page is
# otherwise the only way to set it. With it set, Coolify writes
# proxy/dynamic/coolify.yaml itself: the dashboard on coolify:8080, the
# realtime socket on coolify-realtime:6001 and the terminal on :6002, all
# behind TLS, and keeps that file correct across upgrades. Writing those
# routes by hand instead means pinning internal ports that are not ours.
db_user=$(sed -n 's/^DB_USERNAME=//p' "$SOURCE_DIR/.env" | head -1)
db_name=$(sed -n 's/^DB_DATABASE=//p' "$SOURCE_DIR/.env" | head -1)
db_pass=$(sed -n 's/^DB_PASSWORD=//p' "$SOURCE_DIR/.env" | head -1)

docker exec -e PGPASSWORD="$db_pass" coolify-db \
	psql -U "${db_user:-coolify}" -d "${db_name:-coolify}" -v ON_ERROR_STOP=1 \
	-c "UPDATE instance_settings SET fqdn = '${PANEL_URL}', is_dashboard_force_https_enabled = true;" \
	|| echo "[storiza] the dashboard address could not be stored -- set it under Settings"

(cd "$SOURCE_DIR" && docker compose --env-file .env -f docker-compose.yml -f docker-compose.prod.yml up -d) \
	|| echo "[storiza] Coolify did not restart cleanly -- the dashboard may need a moment"
docker exec coolify php artisan app:init > /dev/null 2>&1 || true

# Coolify writes that file when it accepts the address and deletes it when it
# does not, so its presence is the answer to "is the dashboard on HTTPS yet".
HTTPS_READY=no
for _ in $(seq 1 30); do
	if [ -s /data/coolify/proxy/dynamic/coolify.yaml ]; then
		HTTPS_READY=yes
		break
	fi
	sleep 2
done
[ "$HTTPS_READY" = yes ] \
	&& echo "[storiza] the dashboard is served over HTTPS at ${PANEL_URL}" \
	|| echo "[storiza] the dashboard is not on HTTPS yet -- leaving port 8000 open so you can reach it"

step
# 8000 is the dashboard in plaintext. Closing it is only safe once HTTPS is
# actually answering; locking the customer out of a server they paid for is
# worse than a port being open, so it stays open when it has to.
if [ "$HTTPS_READY" = yes ]; then
	allow_ports 80/tcp 443/tcp
	deny_ports 8000/tcp
else
	allow_ports 80/tcp 443/tcp 8000/tcp
fi

credentials <<CREDS
# Coolify

| | |
|---|---|
| URL | ${PANEL_URL} |
| Email | ${ADMIN_EMAIL} |
| Password | ${ADMIN_PASSWORD} |

Coolify serves the dashboard through its own proxy on 443, with the realtime
socket and the terminal alongside it. Port 8000 is the same dashboard in
plaintext; it is closed to the internet once HTTPS answers, and left open if
it does not, so you are never locked out of your own server.

Do give the dashboard a domain soon. Until it has one the connection is
encrypted but nothing vouches for the certificate, so the browser cannot tell
you whether the server answering is really yours. Point a domain at this
server, then set it along with a certificate resolver under Settings and
Coolify asks Let's Encrypt for a real one.

Ports 80 and 443 also route the applications you deploy. Everything else is
closed -- open what you need with \`ufw allow <port>\`.
CREDS

echo "[storiza] Coolify ready at ${PANEL_URL}"
