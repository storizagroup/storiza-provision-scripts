#!/usr/bin/env bash
#
# Coolify -- Storiza provision script.
#
# Inputs consumed:
#     inputs.admin_email     -- becomes Coolify's root user, required
#     inputs.admin_password  -- its password, required
#     inputs.panel_domain    -- optional; see below
#
# HTTPS, and why it is done this way:
#
# Coolify runs its own Traefik on ports 80 and 443 to route the applications
# the customer deploys. Putting another web server on 443 would take that away
# from them, so this script does not. Instead:
#
#   * with a domain -- the domain is written into Coolify's own settings and
#     Coolify's Traefik issues the certificate on 443, which is how upstream
#     intends it to work.
#   * without one -- nginx terminates TLS on 8443 and proxies to the dashboard
#     on 8000, so the dashboard is never served in plaintext, and 80 and 443
#     stay free for Traefik.
#
# Ports: 80, 443 and 8443 only. 8000 is denied explicitly because Coolify
# publishes it through Docker, which bypasses the allow list.
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
	"Publishing the dashboard over HTTPS" \
	"Closing the ports nothing should reach"

step
ADMIN_EMAIL=$(need '.inputs.admin_email')
ADMIN_PASSWORD=$(need '.inputs.admin_password')
PANEL_DOMAIN=$(answer '.inputs.panel_domain')

step
pkg curl nginx openssl
# nginx is only wanted for the no-domain case; stop it holding 80 while the
# installer brings Traefik up.
systemctl stop nginx || true

step
echo "[storiza] running the Coolify installer -- this takes several minutes"
curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/coolify-install.sh
ROOT_USERNAME="admin" \
	ROOT_USER_EMAIL="$ADMIN_EMAIL" \
	ROOT_USER_PASSWORD="$ADMIN_PASSWORD" \
	bash /tmp/coolify-install.sh || fail "The Coolify installer did not finish."
rm -f /tmp/coolify-install.sh

step
if [ -n "$PANEL_DOMAIN" ]; then
	# Coolify reads its own FQDN from the environment file it was installed
	# with; setting it here means Traefik asks Let's Encrypt for the
	# certificate on the next start.
	if [ -f /data/coolify/source/.env ]; then
		sed -i "s|^APP_URL=.*|APP_URL=https://${PANEL_DOMAIN}|" /data/coolify/source/.env
		grep -q '^APP_URL=' /data/coolify/source/.env \
			|| echo "APP_URL=https://${PANEL_DOMAIN}" >> /data/coolify/source/.env
		(cd /data/coolify/source && docker compose up -d --force-recreate) || true
	fi
	systemctl disable --now nginx || true
	PANEL_URL="https://${PANEL_DOMAIN}"
	CERT_NOTE="Let's Encrypt, issued by Coolify's proxy once the domain resolves here"
else
	serve_https 8000 8443
fi

step
allow_ports 80/tcp 443/tcp 8443/tcp
deny_ports 8000/tcp

credentials <<CREDS
# Coolify

| | |
|---|---|
| URL | ${PANEL_URL} |
| Email | ${ADMIN_EMAIL} |
| Password | ${ADMIN_PASSWORD} |
| Certificate | ${CERT_NOTE} |

Ports 80 and 443 belong to Coolify's own proxy, which is what routes the
applications you deploy. Leave them to it. Everything else is closed -- open
what you need with \`ufw allow <port>\`.
CREDS

echo "[storiza] Coolify ready at ${PANEL_URL}"
