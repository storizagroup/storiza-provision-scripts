#!/usr/bin/env bash
#
# MCSManager -- Storiza provision script.
#
# Run once by cloud-init while a Storiza VPS first boots. The customer's
# answers arrive in a file, never as arguments:
#
#     /etc/storiza/provision.json   { "vps": {...}, "inputs": {...} }
#
# Inputs consumed:
#     inputs.panel_domain    -- optional; the panel answers on the IP without it
#
# ⚠ MCSManager creates its administrator through the browser on first visit.
# There is no supported way to pre-seed it, so the instructions tell the
# customer to open the panel and claim it immediately.
#
# Installed from the GitHub release rather than script.mcsmanager.com: the
# release is the same artifact, is reachable from anywhere, and can be
# inspected before it runs.
#
# HTTPS: MCSManager serves plain HTTP on 23333, and it is a panel that hands
# out server consoles and file access, so nginx terminates TLS in front of it
# -- Let's Encrypt when a domain was answered and its DNS already points here,
# self-signed otherwise. 23333 is left bound to localhost.
#
# Upstream: https://mcsmanager.com  (Apache-2.0, MCSManager)
# Release: https://github.com/MCSManager/MCSManager/releases
set -euo pipefail

LOG=/var/log/storiza-provision.log
exec > >(tee -a "$LOG") 2>&1
echo "[storiza] MCSManager provisioning started $(date -Is)"

DATA=${PROVISION_DATA:-/etc/storiza/provision.json}
[ -r "$DATA" ] || { echo "[storiza] $DATA missing -- nothing to install"; exit 1; }

command -v jq >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y jq >/dev/null; }
answer() { jq -r "$1 // empty" "$DATA"; }

PANEL_DOMAIN=$(answer '.inputs.panel_domain')
IP_ADDRESS=$(answer '.vps.ip.address')

INSTALL_DIR=/opt/mcsmanager
RELEASE_URL=https://github.com/MCSManager/MCSManager/releases/latest/download/mcsmanager_linux_release.tar.gz

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y curl wget tar nginx openssl certbot python3-certbot-nginx openjdk-21-jre-headless >/dev/null

# Ubuntu 24.04 ships Node 18; MCSManager needs 20 or newer.
if ! node --version 2>/dev/null | grep -qE "^v(2[0-9]|[3-9][0-9])\."; then
	echo "[storiza] installing Node.js 20"
	curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource.sh
	bash /tmp/nodesource.sh >/dev/null
	apt-get install -y nodejs >/dev/null
	rm -f /tmp/nodesource.sh
fi

echo "[storiza] downloading MCSManager"
mkdir -p "$INSTALL_DIR"
curl -fsSL "$RELEASE_URL" -o /tmp/mcsmanager.tar.gz
tar -xzf /tmp/mcsmanager.tar.gz -C "$INSTALL_DIR" --strip-components 1
rm -f /tmp/mcsmanager.tar.gz

echo "[storiza] installing dependencies"
(cd "$INSTALL_DIR/daemon" && npm install --production --no-fund --no-audit >/dev/null)
(cd "$INSTALL_DIR/web" && npm install --production --no-fund --no-audit >/dev/null)

for unit in daemon web; do
	port=24444
	[ "$unit" = "web" ] && port=23333
	cat > "/etc/systemd/system/mcsm-${unit}.service" <<UNIT
[Unit]
Description=MCSManager ${unit} (port ${port})
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}/${unit}
ExecStart=/usr/bin/node app.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
UNIT
done

systemctl daemon-reload
systemctl enable --now mcsm-daemon mcsm-web

# ── TLS in front of the panel ───────────────────────────────────────────────
mkdir -p /etc/storiza/ssl
SAN="IP:${IP_ADDRESS}"
[ -n "$PANEL_DOMAIN" ] && SAN="DNS:${PANEL_DOMAIN},${SAN}"
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -sha256 \
	-keyout /etc/storiza/ssl/self.key -out /etc/storiza/ssl/self.crt \
	-subj "/CN=${PANEL_DOMAIN:-$IP_ADDRESS}" -addext "subjectAltName=${SAN}" 2>/dev/null
chmod 600 /etc/storiza/ssl/self.key

cat > /etc/nginx/sites-available/mcsmanager.conf <<NGINX
server {
    listen 80;
    server_name ${PANEL_DOMAIN:-_};

    location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    server_name ${PANEL_DOMAIN:-_};

    ssl_certificate     /etc/storiza/ssl/self.crt;
    ssl_certificate_key /etc/storiza/ssl/self.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 2048m;

    location / {
        proxy_pass http://127.0.0.1:23333;
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
ln -sf /etc/nginx/sites-available/mcsmanager.conf /etc/nginx/sites-enabled/mcsmanager.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx

CERT_NOTE="self-signed -- the browser warns once"
if [ -n "$PANEL_DOMAIN" ]; then
	echo "[storiza] requesting a Let's Encrypt certificate for ${PANEL_DOMAIN}"
	if certbot --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos \
		--register-unsafely-without-email --redirect --keep-until-expiring; then
		CERT_NOTE="Let's Encrypt (trusted)"
	else
		echo "[storiza] Let's Encrypt could not verify ${PANEL_DOMAIN} -- keeping the self-signed certificate"
		echo "[storiza] once its A record resolves here, run: certbot --nginx -d ${PANEL_DOMAIN}"
	fi
	systemctl reload nginx || true
fi

PANEL_URL="https://${PANEL_DOMAIN:-$IP_ADDRESS}"

cat > /root/mcsmanager-credentials.md <<CREDS
# MCSManager

| | |
|---|---|
| URL | ${PANEL_URL} |
| Account | none yet -- the first visitor creates the administrator |
| Certificate | ${CERT_NOTE} |

⚠ Open the URL and create the administrator now. Until you do, anyone who
finds this server can claim it.

Java 21 is installed for Minecraft servers. The panel is on 443; the daemon
listens on 24444 for the panel itself.
CREDS
chmod 600 /root/mcsmanager-credentials.md

echo "[storiza] MCSManager ready at ${PANEL_URL} -- create the administrator now"
echo "[storiza] MCSManager provisioning finished $(date -Is)"
