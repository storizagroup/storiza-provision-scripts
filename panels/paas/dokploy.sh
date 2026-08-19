#!/usr/bin/env bash
#
# Dokploy -- Storiza provision script.
#
# Run once by cloud-init while a Storiza VPS first boots. The customer's
# answers arrive in a file, never as arguments:
#
#     /etc/storiza/provision.json   { "vps": {...}, "inputs": {...} }
#
# Inputs consumed:
#     inputs.panel_domain    -- optional; see below
#
# ⚠ Dokploy has no supported way to create its first account without a
# browser: whoever opens the dashboard first registers as the owner. There is
# nothing to pre-seed, so this script does not pretend to -- it installs
# Dokploy, puts TLS in front of the dashboard, and the instructions tell the
# customer to register immediately.
#
# HTTPS: Dokploy runs Traefik on 80 and 443 for the applications the customer
# deploys, so this script leaves those alone. nginx terminates TLS on 8443 and
# proxies to the dashboard on 3000, so the registration form -- where the
# owner password is chosen -- is never served in plaintext. With a domain, set
# it in Dokploy's own Web Server settings afterwards and its proxy will issue
# a Let's Encrypt certificate on 443.
#
# Upstream: https://dokploy.com  (Apache-2.0)
# Installer: https://dokploy.com/install.sh
set -euo pipefail

LOG=/var/log/storiza-provision.log
exec > >(tee -a "$LOG") 2>&1
echo "[storiza] Dokploy provisioning started $(date -Is)"

DATA=${PROVISION_DATA:-/etc/storiza/provision.json}
[ -r "$DATA" ] || { echo "[storiza] $DATA missing -- nothing to install"; exit 1; }

command -v jq >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y jq >/dev/null; }
answer() { jq -r "$1 // empty" "$DATA"; }

PANEL_DOMAIN=$(answer '.inputs.panel_domain')
IP_ADDRESS=$(answer '.vps.ip.address')

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y curl nginx openssl >/dev/null

# The installer aborts if anything holds port 3000, and nginx must not be on
# 80 while Traefik claims it.
systemctl stop nginx || true

echo "[storiza] running the Dokploy installer (this takes several minutes)"
curl -fsSL https://dokploy.com/install.sh -o /tmp/dokploy-install.sh
sh /tmp/dokploy-install.sh
rm -f /tmp/dokploy-install.sh

mkdir -p /etc/storiza/ssl
SAN="IP:${IP_ADDRESS}"
[ -n "$PANEL_DOMAIN" ] && SAN="DNS:${PANEL_DOMAIN},${SAN}"
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -sha256 \
	-keyout /etc/storiza/ssl/self.key -out /etc/storiza/ssl/self.crt \
	-subj "/CN=${PANEL_DOMAIN:-$IP_ADDRESS}" -addext "subjectAltName=${SAN}" 2>/dev/null
chmod 600 /etc/storiza/ssl/self.key

cat > /etc/nginx/sites-available/dokploy.conf <<NGINX
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
ln -sf /etc/nginx/sites-available/dokploy.conf /etc/nginx/sites-enabled/dokploy.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx

PANEL_URL="https://${PANEL_DOMAIN:-$IP_ADDRESS}:8443"

cat > /root/dokploy-credentials.md <<CREDS
# Dokploy

| | |
|---|---|
| URL | ${PANEL_URL} |
| Account | none yet -- the first visitor registers as the owner |

⚠ Open the URL and register now. Until you do, anyone who finds this server
can claim it.

The certificate is self-signed, so the browser warns once. To get a real one,
point a domain at this server and set it under Web Server -> Domain in
Dokploy; its own proxy will issue a Let's Encrypt certificate on 443.

Ports 80 and 443 belong to Dokploy's proxy, which routes the applications you
deploy. Leave them to it.
CREDS
chmod 600 /root/dokploy-credentials.md

echo "[storiza] Dokploy ready at ${PANEL_URL} -- register the owner account now"
echo "[storiza] Dokploy provisioning finished $(date -Is)"
