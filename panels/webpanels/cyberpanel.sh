#!/usr/bin/env bash
#
# CyberPanel (OpenLiteSpeed edition) -- Storiza provision script.
#
# Run once by cloud-init while a Storiza VPS first boots. The customer's
# answers arrive in a file, never as arguments:
#
#     /etc/storiza/provision.json   { "vps": {...}, "inputs": {...} }
#
# Inputs consumed:
#     inputs.admin_password  -- the panel's admin password, required
#     inputs.panel_domain    -- optional; the panel answers on the IP without it
#
# CyberPanel serves its interface over HTTPS on port 8090 with a self-signed
# certificate, so nothing here is plaintext. The
# password is handed to the installer through its documented `-p` flag rather
# than left at the default 1234567, which is what an unattended install would
# otherwise leave the panel sitting on.
#
# Upstream: https://cyberpanel.net  (GPL-3.0, CyberPersons LLC)
# Installer: https://cyberpanel.net/install.sh
set -euo pipefail

LOG=/var/log/storiza-provision.log
exec > >(tee -a "$LOG") 2>&1
echo "[storiza] CyberPanel provisioning started $(date -Is)"

DATA=${PROVISION_DATA:-/etc/storiza/provision.json}
[ -r "$DATA" ] || { echo "[storiza] $DATA missing -- nothing to install"; exit 1; }

command -v jq >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y jq >/dev/null; }
answer() { jq -r "$1 // empty" "$DATA"; }

ADMIN_PASSWORD=$(answer '.inputs.admin_password')
PANEL_DOMAIN=$(answer '.inputs.panel_domain')
IP_ADDRESS=$(answer '.vps.ip.address')

[ -n "$ADMIN_PASSWORD" ] || { echo "[storiza] inputs.admin_password is required"; exit 1; }

export DEBIAN_FRONTEND=noninteractive

. /etc/os-release
case "${VERSION_ID:-}" in
	20.04 | 22.04 | 24.04 | 26.04) ;;
	*)
		echo "[storiza] CyberPanel supports Ubuntu 20.04, 22.04, 24.04 and 26.04 -- found ${PRETTY_NAME:-unknown}"
		exit 1
		;;
esac

apt-get update -qq
apt-get install -y curl wget >/dev/null

# `-v ols` and `-p` both put the installer into its silent mode, so it never
# stops to ask about the edition, the database or the password.
echo "[storiza] running the CyberPanel installer (this takes 10-20 minutes)"
curl -fsSL https://cyberpanel.net/install.sh -o /tmp/cyberpanel-install.sh
sh /tmp/cyberpanel-install.sh -v ols -p "$ADMIN_PASSWORD"
rm -f /tmp/cyberpanel-install.sh

# The installer writes the password to a root-only file of its own; ours is
# just the summary the customer is pointed at.
PANEL_HOST="${PANEL_DOMAIN:-$IP_ADDRESS}"

cat > /root/cyberpanel-credentials.md <<CREDS
# CyberPanel

| | |
|---|---|
| URL | https://${PANEL_HOST}:8090 |
| Username | admin |
| Password | the one you chose when ordering |

The certificate is self-signed, so the browser warns once. Issue a real one
from SSL -> Hostname SSL after pointing a domain at this server.

Other services installed: OpenLiteSpeed (80/443), PowerDNS, Postfix,
Pure-FTPd, phpMyAdmin, Snappymail.

> Keep this file secure. Consider deleting it once the password is stored
> somewhere safe.
CREDS
chmod 600 /root/cyberpanel-credentials.md

echo "[storiza] CyberPanel ready at https://${PANEL_HOST}:8090"
echo "[storiza] CyberPanel provisioning finished $(date -Is)"
