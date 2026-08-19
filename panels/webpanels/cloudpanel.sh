#!/usr/bin/env bash
#
# CloudPanel -- Storiza provision script.
#
# Run once by cloud-init while a Storiza VPS first boots. The customer's
# answers arrive in a file, never as arguments:
#
#     /etc/storiza/provision.json   { "vps": {...}, "inputs": {...} }
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
# Upstream: https://www.cloudpanel.io  (MGT-COMMERCE GmbH)
# Installer: https://installer.cloudpanel.io/ce/v2/install.sh
set -euo pipefail

LOG=/var/log/storiza-provision.log
exec > >(tee -a "$LOG") 2>&1
echo "[storiza] CloudPanel provisioning started $(date -Is)"

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

# The installer refuses anything but a supported Ubuntu, and refuses a server
# that is not empty. Better to say so here than half-install.
. /etc/os-release
case "${VERSION_ID:-}" in
	22.04 | 24.04 | 26.04) ;;
	*)
		echo "[storiza] CloudPanel supports Ubuntu 22.04, 24.04 and 26.04 -- found ${PRETTY_NAME:-unknown}"
		exit 1
		;;
esac

apt-get update -qq
apt-get install -y curl wget sudo >/dev/null

# Fetched over TLS from the vendor and run as-is, which is what CloudPanel's
# own documentation tells you to do. There is no published checksum to pin.
echo "[storiza] running the CloudPanel installer (this takes several minutes)"
curl -fsSL https://installer.cloudpanel.io/ce/v2/install.sh -o /tmp/cloudpanel-install.sh
DB_ENGINE=MARIADB_11.4 bash /tmp/cloudpanel-install.sh
rm -f /tmp/cloudpanel-install.sh

# CloudPanel would otherwise wait for someone to open the browser and create
# the first account, leaving the panel open to whoever gets there first.
echo "[storiza] creating the admin account"
clpctl user:add \
	--userName='admin' \
	--email="$ADMIN_EMAIL" \
	--firstName='Server' \
	--lastName='Administrator' \
	--password="$ADMIN_PASSWORD" \
	--role='admin' \
	--timezone='UTC' \
	--status='1'

PANEL_URL="https://${PANEL_DOMAIN:-$IP_ADDRESS}:8443"

cat > /root/cloudpanel-credentials.md <<CREDS
# CloudPanel

| | |
|---|---|
| URL | ${PANEL_URL} |
| Username | admin |
| Email | ${ADMIN_EMAIL} |
| Password | the one you chose when ordering |

The certificate is self-signed, so the browser warns once. Add a domain from
Admin Area -> Settings to replace it with a free Let's Encrypt certificate.

> Keep this file secure. Consider deleting it once the password is stored
> somewhere safe.
CREDS
chmod 600 /root/cloudpanel-credentials.md

echo "[storiza] CloudPanel ready at ${PANEL_URL}"
echo "[storiza] CloudPanel provisioning finished $(date -Is)"
