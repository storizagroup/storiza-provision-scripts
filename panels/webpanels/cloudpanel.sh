#!/usr/bin/env bash
#
# CloudPanel -- Storiza provision script.
#
# Inputs consumed:
#     inputs.admin_email     -- the first admin account, required
#     inputs.admin_password  -- its password, required
#     inputs.panel_domain    -- optional; the panel answers on the IP without it
#
# CloudPanel serves its own interface over HTTPS on port 8443 with a
# self-signed certificate, so there is no plaintext step to close here. A
# domain is not needed for that and is only used to label the install.
#
# Ports: 80 and 443 for the sites it hosts, 8443 for the panel. Nothing else,
# and no Docker to work around.
#
# Upstream: https://www.cloudpanel.io  (MGT-COMMERCE GmbH)
# Installer: https://installer.cloudpanel.io/ce/v2/install.sh
set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/storizagroup/storiza-provision-scripts/main/lib/provision.sh \
	-o /tmp/storiza-lib.sh && . /tmp/storiza-lib.sh

storiza_start "CloudPanel" \
	"Reading your answers" \
	"Installing system dependencies" \
	"Installing CloudPanel" \
	"Creating the administrator" \
	"Closing the ports nothing should reach"

step
ADMIN_EMAIL=$(need '.inputs.admin_email')
ADMIN_PASSWORD=$(need '.inputs.admin_password')
PANEL_DOMAIN=$(answer '.inputs.panel_domain')
IP_ADDRESS=$(answer '.vps.ip.address')

# The installer refuses anything but a supported Ubuntu, and refuses a server
# that is not empty. Better to say so here than half-install.
supported_ubuntu 22.04 24.04 26.04

step
pkg curl wget sudo

step
# Fetched over TLS from the vendor and run as-is, which is what CloudPanel's
# own documentation tells you to do. There is no published checksum to pin.
echo "[storiza] running the CloudPanel installer -- this takes several minutes"
curl -fsSL https://installer.cloudpanel.io/ce/v2/install.sh -o /tmp/cloudpanel-install.sh
DB_ENGINE=MARIADB_11.4 bash /tmp/cloudpanel-install.sh \
	|| fail "The CloudPanel installer did not finish."
rm -f /tmp/cloudpanel-install.sh

step
# CloudPanel would otherwise wait for someone to open the browser and create
# the first account, leaving the panel open to whoever gets there first.
clpctl user:add \
	--userName='admin' \
	--email="$ADMIN_EMAIL" \
	--firstName='Server' \
	--lastName='Administrator' \
	--password="$ADMIN_PASSWORD" \
	--role='admin' \
	--timezone='UTC' \
	--status='1' \
	|| fail "CloudPanel installed, but the administrator account could not be created."

step
allow_ports 80/tcp 443/tcp 8443/tcp

PANEL_URL="https://${PANEL_DOMAIN:-$IP_ADDRESS}:8443"

credentials <<CREDS
# CloudPanel

| | |
|---|---|
| URL | ${PANEL_URL} |
| Username | admin |
| Email | ${ADMIN_EMAIL} |
| Password | the one you chose when ordering |

The certificate is self-signed, so the browser warns once. Add a domain from
Admin Area -> Settings to replace it with a free Let's Encrypt certificate.

Only 80, 443, 8443 and SSH accept connections. Open anything else with
\`ufw allow <port>\`.
CREDS

echo "[storiza] CloudPanel ready at ${PANEL_URL}"
