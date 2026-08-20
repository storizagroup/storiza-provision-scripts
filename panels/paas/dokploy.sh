#!/usr/bin/env bash
#
# Dokploy -- Storiza provision script.
#
# Inputs consumed:
#     inputs.panel_domain    -- optional; see below
#
# Dokploy has no supported way to create its first account without a browser:
# whoever opens the dashboard first registers as the owner. There is nothing
# to pre-seed, so this script does not pretend to -- it installs Dokploy, puts
# TLS in front of the dashboard, and the instructions tell the customer to
# register immediately.
#
# HTTPS: Dokploy runs Traefik on 80 and 443 for the applications the customer
# deploys, so this script leaves those alone. nginx terminates TLS on 8443 in
# front of the dashboard on 3000, so the registration form -- where the owner
# password is chosen -- is never served in plaintext. With a domain, set it in
# Dokploy's own Web Server settings afterwards and its proxy will issue a
# Let's Encrypt certificate on 443.
#
# Ports: 80, 443 and 8443 only. 3000 is denied explicitly because Dokploy
# publishes it through Docker, which bypasses the allow list.
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
	"Publishing the dashboard over HTTPS" \
	"Closing the ports nothing should reach"

step
PANEL_DOMAIN=$(answer '.inputs.panel_domain')

step
pkg curl nginx openssl
# The installer aborts if anything holds port 3000, and nginx must not be on
# 80 while Traefik claims it.
systemctl stop nginx || true

step
echo "[storiza] running the Dokploy installer -- this takes several minutes"
curl -fsSL https://dokploy.com/install.sh -o /tmp/dokploy-install.sh
sh /tmp/dokploy-install.sh || fail "The Dokploy installer did not finish."
rm -f /tmp/dokploy-install.sh

step
# No domain passed on purpose: an http-01 challenge needs port 80, which
# belongs to Dokploy's Traefik. Dokploy issues that certificate itself.
serve_https 3000 8443
[ -z "$PANEL_DOMAIN" ] || PANEL_URL="https://${PANEL_DOMAIN}:8443"

step
allow_ports 80/tcp 443/tcp 8443/tcp
deny_ports 3000/tcp

credentials <<CREDS
# Dokploy

| | |
|---|---|
| URL | ${PANEL_URL} |
| Account | none yet -- the first visitor registers as the owner |

Open the URL and register now. Until you do, anyone who finds this server can
claim it.

The certificate is ${CERT_NOTE}. To get a real one, point a domain at this
server and set it under Web Server -> Domain in Dokploy; its own proxy will
issue a Let's Encrypt certificate on 443.

Ports 80 and 443 belong to Dokploy's proxy, which routes the applications you
deploy. Leave them to it. Everything else is closed -- open what you need with
\`ufw allow <port>\`.
CREDS

echo "[storiza] Dokploy ready at ${PANEL_URL} -- register the owner account now"
