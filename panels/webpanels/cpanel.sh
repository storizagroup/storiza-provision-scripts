#!/usr/bin/env bash
#
# cPanel & WHM -- Storiza provision script.
#
# Run once by cloud-init while a Storiza VPS first boots. The customer's
# answers arrive in a file, never as arguments:
#
#     /etc/storiza/provision.json   { "vps": {...}, "inputs": {...} }
#
# Inputs consumed:
#     inputs.server_hostname  -- fully qualified, required (see below)
#
# ⚠ cPanel & WHM is commercial software published by cPanel, L.L.C. It is not
# free and no licence is included with the server: the install starts a trial
# if the IP qualifies, and after that a licence has to be bought from cPanel
# or a partner. This script only runs the vendor's own public installer; it
# does not bundle, modify or unlock anything.
#
# ⚠ The hostname must be a fully qualified domain name that is NOT the same as
# any domain you plan to host on the server (cPanel refuses to add a domain
# that matches the hostname). Something like server.example.com. The installer
# checks this before it does anything expensive, and so does this script.
#
# cPanel serves WHM on 2087 and cPanel on 2083, both HTTPS with a self-signed
# certificate until AutoSSL replaces it once the hostname resolves. Nothing is
# added in front of it -- cPanel manages ports 80, 443, 2083 and 2087 itself,
# and a second web server would fight it.
#
# Upstream: https://cpanel.net
# Installer: https://securedownloads.cpanel.net/latest
set -euo pipefail

LOG=/var/log/storiza-provision.log
exec > >(tee -a "$LOG") 2>&1
echo "[storiza] cPanel provisioning started $(date -Is)"

DATA=${PROVISION_DATA:-/etc/storiza/provision.json}
[ -r "$DATA" ] || { echo "[storiza] $DATA missing -- nothing to install"; exit 1; }

command -v jq >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y jq >/dev/null; }
answer() { jq -r "$1 // empty" "$DATA"; }

SERVER_HOSTNAME=$(answer '.inputs.server_hostname')
IP_ADDRESS=$(answer '.vps.ip.address')

[ -n "$SERVER_HOSTNAME" ] || {
	echo "[storiza] inputs.server_hostname is required and must be a fully qualified name"
	exit 1
}
case "$SERVER_HOSTNAME" in
	*.*.*) ;;
	*)
		echo "[storiza] '${SERVER_HOSTNAME}' is not fully qualified -- cPanel needs something like server.example.com"
		exit 1
		;;
esac

# cPanel installs on a bare machine and manages the stack itself. Anything we
# add first -- a web server, a database -- makes the install fail.
for blocker in nginx apache2 mysql-server mariadb-server; do
	if dpkg -l "$blocker" 2>/dev/null | grep -q "^ii"; then
		echo "[storiza] ${blocker} is installed; cPanel requires a clean server"
		exit 1
	fi
done

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y curl perl >/dev/null

hostnamectl set-hostname "$SERVER_HOSTNAME"
if ! grep -q "$SERVER_HOSTNAME" /etc/hosts; then
	echo "${IP_ADDRESS} ${SERVER_HOSTNAME} ${SERVER_HOSTNAME%%.*}" >> /etc/hosts
fi

echo "[storiza] running the cPanel installer -- this takes 30-60 minutes"
cd /home
curl -fsSL -o latest https://securedownloads.cpanel.net/latest
sh latest
rm -f /home/latest

cat > /root/cpanel-credentials.md <<CREDS
# cPanel & WHM

| | |
|---|---|
| WHM | https://${SERVER_HOSTNAME}:2087 (or https://${IP_ADDRESS}:2087) |
| cPanel | https://${SERVER_HOSTNAME}:2083 |
| Username | root |
| Password | your server's root password |

## Licence

cPanel is commercial software and no licence is included with this server.
Sign in to WHM and it will walk you through starting the 15-day trial, or
enter a licence bought from cPanel or one of their partners. The licence is
tied to this server's IP address (${IP_ADDRESS}), so keep the IP if you buy
one.

The certificate is self-signed until AutoSSL replaces it, which needs
${SERVER_HOSTNAME} to resolve to ${IP_ADDRESS}.
CREDS
chmod 600 /root/cpanel-credentials.md

echo "[storiza] WHM ready at https://${IP_ADDRESS}:2087 -- sign in as root"
echo "[storiza] cPanel provisioning finished $(date -Is)"
