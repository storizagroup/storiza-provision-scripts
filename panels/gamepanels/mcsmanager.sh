#!/usr/bin/env bash
#
# MCSManager -- Storiza provision script.
#
# Inputs consumed:
#     inputs.panel_domain    -- optional; the panel answers on the IP without it
#
# MCSManager creates its administrator through the browser on first visit.
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
# self-signed otherwise.
#
# Ports: no allow list. This is a game panel; the whole point is that the
# customer opens 25565 and whatever else their servers need. Instead the two
# ports that must never be reached from outside are closed -- 23333, which is
# the panel in plaintext, and 24444, the daemon that the panel talks to over
# localhost.
#
# Upstream: https://mcsmanager.com  (Apache-2.0, MCSManager)
# Release: https://github.com/MCSManager/MCSManager/releases
set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/storizagroup/storiza-provision-scripts/main/lib/provision.sh \
	-o /tmp/storiza-lib.sh && . /tmp/storiza-lib.sh

storiza_start "MCSManager" \
	"Reading your answers" \
	"Installing Java and Node.js" \
	"Downloading MCSManager" \
	"Installing its dependencies" \
	"Starting the panel" \
	"Publishing the panel over HTTPS" \
	"Closing the panel's own ports"

INSTALL_DIR=/opt/mcsmanager
RELEASE_URL=https://github.com/MCSManager/MCSManager/releases/latest/download/mcsmanager_linux_release.tar.gz

step
PANEL_DOMAIN=$(answer '.inputs.panel_domain')

step
pkg curl wget tar openjdk-21-jre-headless
# Ubuntu 24.04 ships Node 18; MCSManager needs 20 or newer.
if ! node --version 2> /dev/null | grep -qE "^v(2[0-9]|[3-9][0-9])\."; then
	echo "[storiza] installing Node.js 20"
	curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource.sh
	bash /tmp/nodesource.sh > /dev/null
	pkg nodejs
	rm -f /tmp/nodesource.sh
fi

step
mkdir -p "$INSTALL_DIR"
curl -fsSL "$RELEASE_URL" -o /tmp/mcsmanager.tar.gz
tar -xzf /tmp/mcsmanager.tar.gz -C "$INSTALL_DIR" --strip-components 1
rm -f /tmp/mcsmanager.tar.gz

step
(cd "$INSTALL_DIR/daemon" && npm install --production --no-fund --no-audit > /dev/null)
(cd "$INSTALL_DIR/web" && npm install --production --no-fund --no-audit > /dev/null)

step
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

step
serve_https 23333 443 "$PANEL_DOMAIN"

step
deny_ports 23333/tcp 24444/tcp

credentials <<CREDS
# MCSManager

| | |
|---|---|
| URL | ${PANEL_URL} |
| Account | none yet -- the first visitor creates the administrator |
| Certificate | ${CERT_NOTE} |

Open the URL and create the administrator now. Until you do, anyone who finds
this server can claim it.

Java 21 is installed for Minecraft servers. The panel answers on 443; 23333
and 24444 are closed from outside, which is where the panel and its daemon
talk to each other.

Game server ports are yours to open -- \`ufw allow 25565/tcp\` and so on.
CREDS

echo "[storiza] MCSManager ready at ${PANEL_URL} -- create the administrator now"
