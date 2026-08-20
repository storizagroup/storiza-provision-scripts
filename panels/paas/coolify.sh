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
# Coolify is served by its own Traefik on 80 and 443, and it must be. The
# dashboard is a Laravel application that builds every asset URL from the
# address the browser asked for, so putting it behind nginx on another port
# gives you a page on :8443 asking for its stylesheets on :443, and a realtime
# socket dialling a port that answers in plaintext. The panel half-loads and
# nothing explains why.
#
# So nothing is put in front of Coolify. Instead its own proxy is told to
# serve the dashboard over TLS, through a dynamic configuration file of ours
# in /data/coolify/proxy/dynamic, and APP_URL is set to match:
#
#   * with a domain -- Traefik's letsencrypt resolver issues a real
#     certificate for it, which is how upstream intends this to work.
#   * without one -- no certificate authority will vouch for an IP address, so
#     Traefik answers with the certificate it generates for itself. The
#     browser warns once, which beats a password crossing the network in the
#     clear. Point a domain at the server and set it under Settings to replace
#     it with a real one.
#
# Either way port 80 redirects to 443 at the proxy, and 8000 -- the
# dashboard's own plaintext port -- is closed to the internet, so there is no
# way in that is not HTTPS.
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
	"Serving the dashboard over HTTPS" \
	"Closing the ports nothing should reach"

PROXY_DIR=/data/coolify/proxy
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
[ -d "$PROXY_DIR" ] || fail "Coolify installed without its proxy directory -- nothing to configure."
mkdir -p "$PROXY_DIR/dynamic"

if [ -n "$PANEL_DOMAIN" ]; then
	# Traefik asks Let's Encrypt the first time the domain is requested, and
	# keeps trying, so a DNS record that is not ready yet costs nothing here.
	# A flow mapping, because this is substituted after "tls:" on one line.
	ROUTER_TLS="{certResolver: letsencrypt}"
	CERT_NOTE="Let's Encrypt, issued by Coolify's proxy once ${PANEL_DOMAIN} resolves here"
else
	# No certificate is made here. An empty tls block puts the router on the
	# https entrypoint and lets Traefik answer with the certificate it
	# generates for itself, which is untrusted but encrypted -- and no
	# authority would vouch for an IP address anyway. One less command that
	# can fail on the way to a working dashboard.
	ROUTER_TLS="{}"
	CERT_NOTE="Traefik's own -- encrypted, but the browser warns because nothing vouches for an IP address"
fi

# Named storiza-* so that setting an instance domain from Coolify's own
# Settings page later adds its routers alongside these rather than clashing
# with them.
cat > "$PROXY_DIR/dynamic/storiza.yaml" <<YAML
# Written by Storiza when this server was provisioned. Serving the dashboard
# over TLS is all this does. Setting an instance domain from Settings adds
# Coolify's own routing beside it; this file only ever matches ${PANEL_HOST},
# so it can stay or go as you prefer.
http:
  middlewares:
    storiza-https:
      redirectScheme:
        scheme: https
  routers:
    storiza-dashboard-http:
      rule: Host(\`${PANEL_HOST}\`)
      entryPoints:
        - http
      service: storiza-dashboard
      middlewares:
        - storiza-https
    storiza-dashboard:
      rule: Host(\`${PANEL_HOST}\`)
      entryPoints:
        - https
      service: storiza-dashboard
      tls: ${ROUTER_TLS}
    storiza-realtime:
      rule: Host(\`${PANEL_HOST}\`) && PathPrefix(\`/app\`)
      entryPoints:
        - https
      service: storiza-realtime
      tls: ${ROUTER_TLS}
  services:
    storiza-dashboard:
      loadBalancer:
        servers:
          - url: http://coolify:8000
    storiza-realtime:
      loadBalancer:
        servers:
          - url: http://coolify-realtime:6001
YAML

# Coolify builds its own URLs from APP_URL, so it has to agree with what the
# proxy is now serving, or the dashboard asks for its assets on the wrong
# scheme and port -- which is the whole reason this script does not use nginx.
if [ -f "$SOURCE_DIR/.env" ]; then
	if grep -q '^APP_URL=' "$SOURCE_DIR/.env"; then
		sed -i "s|^APP_URL=.*|APP_URL=${PANEL_URL}|" "$SOURCE_DIR/.env"
	else
		echo "APP_URL=${PANEL_URL}" >> "$SOURCE_DIR/.env"
	fi
	(cd "$SOURCE_DIR" && docker compose --env-file .env -f docker-compose.yml -f docker-compose.prod.yml up -d) \
		|| echo "[storiza] Coolify did not restart cleanly -- the dashboard may need a moment"
fi

# Traefik picks up the dynamic directory on its own, but Coolify was just
# recreated above and a restart puts the proxy back in front of it without
# waiting for anything to notice.
docker restart coolify-proxy > /dev/null 2>&1 \
	|| echo "[storiza] the proxy did not restart -- check: docker logs coolify-proxy"

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
| Certificate | ${CERT_NOTE} |

The dashboard is served by Coolify's own proxy on 443, and port 80 redirects
to it. Port 8000 is the dashboard's plaintext port and is closed to the
internet, so there is no way in that is not HTTPS.

Those same ports 80 and 443 route the applications you deploy. Everything
else is closed -- open what you need with \`ufw allow <port>\`.

Do give the dashboard a domain soon. Until it has one the connection is
encrypted but nothing vouches for the certificate, so the browser cannot tell
you whether the server answering is really yours. Point a domain here, set it
under Settings, and Coolify's proxy asks Let's Encrypt for a real one.
CREDS

echo "[storiza] Coolify ready at ${PANEL_URL}"
