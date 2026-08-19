#!/usr/bin/env bash
#
# Easypanel -- Storiza provision script.
#
# Run once by cloud-init while a Storiza VPS first boots. The customer's
# answers arrive in a file, never as arguments:
#
#     /etc/storiza/provision.json   { "vps": {...}, "inputs": {...} }
#
# Inputs consumed:
#     inputs.panel_domain    -- optional; see below
#
# ⚠ Like Dokploy, Easypanel has no supported way to create the first account
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
# Upstream: https://easypanel.io
# Installer: https://get.easypanel.io
set -euo pipefail

LOG=/var/log/storiza-provision.log
exec > >(tee -a "$LOG") 2>&1
echo "[storiza] Easypanel provisioning started $(date -Is)"

DATA=${PROVISION_DATA:-/etc/storiza/provision.json}
[ -r "$DATA" ] || { echo "[storiza] $DATA missing -- nothing to install"; exit 1; }

command -v jq >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y jq >/dev/null; }
answer() { jq -r "$1 // empty" "$DATA"; }

PANEL_DOMAIN=$(answer '.inputs.panel_domain')
IP_ADDRESS=$(answer '.vps.ip.address')

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y curl nginx openssl lsof >/dev/null

# The installer checks 80 and 443 with lsof and exits if either is taken, so
# nginx has to be out of the way before it runs -- and must never come back on
# those ports afterwards.
systemctl stop nginx || true

echo "[storiza] running the Easypanel installer (this takes several minutes)"
curl -fsSL https://get.easypanel.io -o /tmp/easypanel-install.sh
sh /tmp/easypanel-install.sh
rm -f /tmp/easypanel-install.sh

mkdir -p /etc/storiza/ssl
SAN="IP:${IP_ADDRESS}"
[ -n "$PANEL_DOMAIN" ] && SAN="DNS:${PANEL_DOMAIN},${SAN}"
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -sha256 \
	-keyout /etc/storiza/ssl/self.key -out /etc/storiza/ssl/self.crt \
	-subj "/CN=${PANEL_DOMAIN:-$IP_ADDRESS}" -addext "subjectAltName=${SAN}" 2>/dev/null
chmod 600 /etc/storiza/ssl/self.key

cat > /etc/nginx/sites-available/easypanel.conf <<NGINX
server {
    listen 8443 ssl;
    server_name _;

    ssl_certificate     /etc/storiza/ssl/self.crt;
    ssl_certificate_key /etc/storiza/ssl/self.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:3000;
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
ln -sf /etc/nginx/sites-available/easypanel.conf /etc/nginx/sites-enabled/easypanel.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx

PANEL_URL="https://${PANEL_DOMAIN:-$IP_ADDRESS}:8443"

cat > /root/easypanel-credentials.md <<CREDS
# Easypanel

| | |
|---|---|
| URL | ${PANEL_URL} |
| Account | none yet -- the first visitor registers as the owner |

⚠ Open the URL and register now. Until you do, anyone who finds this server
can claim it.

The certificate is self-signed, so the browser warns once. Point a domain at
this server and set it in Easypanel's settings to get a real one on 443.

Ports 80 and 443 belong to Easypanel's proxy, which routes the applications
you deploy. Leave them to it.
CREDS
chmod 600 /root/easypanel-credentials.md

echo "[storiza] Easypanel ready at ${PANEL_URL} -- register the owner account now"
echo "[storiza] Easypanel provisioning finished $(date -Is)"
