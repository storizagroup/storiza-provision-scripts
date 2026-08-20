#!/usr/bin/env bash
#
# CyberPanel (OpenLiteSpeed edition) -- Storiza provision script.
#
# Inputs consumed:
#     inputs.admin_password  -- the panel's admin password, required
#     inputs.panel_domain    -- optional; the panel answers on the IP without it
#
# CyberPanel serves its interface over HTTPS on port 8090 with a self-signed
# certificate, so nothing here is plaintext. The password is handed to the
# installer through its documented `-p` flag rather than left at the default
# 1234567, which is what an unattended install would otherwise leave the panel
# sitting on.
#
# Ports: deliberately not touched. CyberPanel installs a mail server, a DNS
# server and an FTP server, each with its own port and its own passive range,
# and it expects to manage the firewall from its own Security page. An allow
# list written here would silently break mail delivery, which is worse than
# the ports being open on a panel that has no plaintext service to begin with.
#
# Upstream: https://cyberpanel.net  (GPL-3.0, CyberPersons LLC)
# Installer: https://cyberpanel.net/install.sh
set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/storizagroup/storiza-provision-scripts/main/lib/provision.sh \
	-o /tmp/storiza-lib.sh && . /tmp/storiza-lib.sh

storiza_start "CyberPanel" \
	"Reading your answers" \
	"Installing system dependencies" \
	"Installing CyberPanel"

step
ADMIN_PASSWORD=$(need '.inputs.admin_password')
PANEL_DOMAIN=$(answer '.inputs.panel_domain')
IP_ADDRESS=$(answer '.vps.ip.address')
supported_ubuntu 20.04 22.04 24.04 26.04

step
pkg curl wget

step
# `-v ols` and `-p` both put the installer into its silent mode, so it never
# stops to ask about the edition, the database or the password.
echo "[storiza] running the CyberPanel installer -- this takes 10-20 minutes"
curl -fsSL https://cyberpanel.net/install.sh -o /tmp/cyberpanel-install.sh
sh /tmp/cyberpanel-install.sh -v ols -p "$ADMIN_PASSWORD" \
	|| fail "The CyberPanel installer did not finish."
rm -f /tmp/cyberpanel-install.sh

PANEL_HOST="${PANEL_DOMAIN:-$IP_ADDRESS}"

# The installer writes the password to a root-only file of its own; ours is
# just the summary the customer is pointed at.
credentials <<CREDS
# CyberPanel

| | |
|---|---|
| URL | https://${PANEL_HOST}:8090 |
| Username | admin |
| Password | the one you chose when ordering |

The certificate is self-signed, so the browser warns once. Issue a real one
from SSL -> Hostname SSL after pointing a domain at this server.

Other services installed: OpenLiteSpeed (80/443), PowerDNS, Postfix,
Pure-FTPd, phpMyAdmin, Snappymail. The firewall is CyberPanel's to manage --
see Security -> Firewall in the panel.
CREDS

echo "[storiza] CyberPanel ready at https://${PANEL_HOST}:8090"
