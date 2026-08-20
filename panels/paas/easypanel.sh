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
# HTTPS: Easypanel's own installer refuses to run if anything is listening on
# port 80 or 443 -- it needs both for its Traefik, which routes the customer's
# applications and issues their certificates. So nginx here binds 8443 only,
# terminating TLS in front of the dashboard on 3000 so the registration form
# is not served in plaintext. Setting a domain inside Easypanel afterwards
# gets the dashboard a real certificate on 443 from its own proxy.
#
# Ports: 80, 443 and 8443 only. 3000 is denied explicitly because Easypanel
# publishes it through Docker, which bypasses the allow list.
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
	"Publishing the dashboard over HTTPS" \
	"Closing the ports nothing should reach"

step
PANEL_DOMAIN=$(answer '.inputs.panel_domain')

step
pkg curl nginx openssl lsof
# The installer checks 80 and 443 with lsof and exits if either is taken, so
# nginx has to be out of the way before it runs -- and must never come back on
# those ports afterwards.
systemctl stop nginx || true

step
echo "[storiza] running the Easypanel installer -- this takes several minutes"
curl -fsSL https://get.easypanel.io -o /tmp/easypanel-install.sh
sh /tmp/easypanel-install.sh || fail "The Easypanel installer did not finish."
rm -f /tmp/easypanel-install.sh

step
# No domain passed on purpose: an http-01 challenge needs port 80, which
# belongs to Easypanel's Traefik. Easypanel issues that certificate itself.
serve_https 3000 8443
[ -z "$PANEL_DOMAIN" ] || PANEL_URL="https://${PANEL_DOMAIN}:8443"

step
allow_ports 80/tcp 443/tcp 8443/tcp
deny_ports 3000/tcp

credentials <<CREDS
# Easypanel

| | |
|---|---|
| URL | ${PANEL_URL} |
| Account | none yet -- the first visitor registers as the owner |

Open the URL and register now. Until you do, anyone who finds this server can
claim it.

The certificate is ${CERT_NOTE}. Point a domain at this server and set it in
Easypanel's settings to get a real one on 443.

Ports 80 and 443 belong to Easypanel's proxy, which routes the applications
you deploy. Leave them to it. Everything else is closed -- open what you need
with \`ufw allow <port>\`.
CREDS

echo "[storiza] Easypanel ready at ${PANEL_URL} -- register the owner account now"
