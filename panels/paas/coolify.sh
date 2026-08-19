#!/usr/bin/env bash
#
# Coolify -- Storiza provision script.
#
# Run once by cloud-init while a Storiza VPS first boots. The customer's
# answers arrive in a file, never as arguments:
#
#     /etc/storiza/provision.json   { "vps": {...}, "inputs": {...} }
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
#   * with a domain -- the domain is written into Coolify's own settings, and
#     Coolify's Traefik issues a Let's Encrypt certificate for the dashboard
#     on 443, which is how upstream intends it to work.
#   * without one -- nginx terminates TLS on 8443 with a self-signed
#     certificate and proxies to the dashboard on 8000, so the dashboard is
#     never served in plaintext. 80 and 443 stay free for Traefik.
#
# The root user is created by the installer from ROOT_USER_* rather than by
# whoever opens the dashboard first.
#
# Upstream: https://coolify.io  (Apache-2.0, coolLabs)
# Installer: https://cdn.coollabs.io/coolify/install.sh
set -euo pipefail

LOG=/var/log/storiza-provision.log
exec > >(tee -a "$LOG") 2>&1
echo "[storiza] Coolify provisioning started $(date -Is)"

DATA=${PROVISION_DATA:-/etc/storiza/provision.json}
[ -r "$DATA" ] || { echo "[storiza] $DATA missing -- nothing to install"; exit 1; }

command -v jq >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y jq >/dev/null; }
answer() { jq -r "$1 // empty" "$DATA"; }

ADMIN_EMAIL=$(answer '.inputs.admin_email')
ADMIN_PASSWORD=$(answer '.inputs.admin_password')
PANEL_DOMAIN=$(answer '.inputs.panel_domain')
IP_ADDRESS=$(answer '.vps.ip.address')

[ -n "$ADMIN_EMAIL" ]    || { echo "[storiza] inputs.admin_email is required"; exit 1; }
[ -n "$ADMIN_PASSWORD" ] || { echo "[storiza] inputs.admin_password is required"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y curl nginx openssl >/dev/null

# nginx is only wanted for the no-domain case; stop it holding 80 while the
# installer brings Traefik up.
systemctl stop nginx || true

echo "[storiza] running the Coolify installer (this takes several minutes)"
curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/coolify-install.sh
ROOT_USERNAME="admin" \
ROOT_USER_EMAIL="$ADMIN_EMAIL" \
ROOT_USER_PASSWORD="$ADMIN_PASSWORD" \
	bash /tmp/coolify-install.sh
rm -f /tmp/coolify-install.sh

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
	# No domain, so no certificate authority will vouch for this server. A
	# self-signed certificate on 8443 still beats sending the password in the
	# clear on 8000.
	mkdir -p /etc/storiza/ssl
	openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -sha256 \
		-keyout /etc/storiza/ssl/self.key -out /etc/storiza/ssl/self.crt \
		-subj "/CN=${IP_ADDRESS}" -addext "subjectAltName=IP:${IP_ADDRESS}" 2>/dev/null
	chmod 600 /etc/storiza/ssl/self.key

	cat > /etc/nginx/sites-available/coolify.conf <<NGINX
server {
    listen 8443 ssl;
    server_name _;

    ssl_certificate     /etc/storiza/ssl/self.crt;
    ssl_certificate_key /etc/storiza/ssl/self.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }
}
NGINX
	rm -f /etc/nginx/sites-enabled/default
	ln -sf /etc/nginx/sites-available/coolify.conf /etc/nginx/sites-enabled/coolify.conf
	nginx -t
	systemctl enable --now nginx
	systemctl restart nginx

	PANEL_URL="https://${IP_ADDRESS}:8443"
	CERT_NOTE="self-signed -- the browser warns once"
fi

cat > /root/coolify-credentials.md <<CREDS
# Coolify

| | |
|---|---|
| URL | ${PANEL_URL} |
| Email | ${ADMIN_EMAIL} |
| Password | the one you chose when ordering |
| Certificate | ${CERT_NOTE} |

Ports 80 and 443 belong to Coolify's own proxy, which is what routes the
applications you deploy. Leave them to it.

> Keep this file secure. Consider deleting it once the password is stored
> somewhere safe.
CREDS
chmod 600 /root/coolify-credentials.md

echo "[storiza] Coolify ready at ${PANEL_URL}"
echo "[storiza] Coolify provisioning finished $(date -Is)"
