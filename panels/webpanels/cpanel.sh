#!/usr/bin/env bash
#
# cPanel & WHM -- Storiza provision script.
#
# Inputs consumed:
#     inputs.server_hostname  -- fully qualified, required (see below)
#
# cPanel & WHM is commercial software published by cPanel, L.L.C. It is not
# free and no licence is included with the server: the install starts a trial
# if the IP qualifies, and after that a licence has to be bought from cPanel
# or a partner. This script only runs the vendor's own public installer; it
# does not bundle, modify or unlock anything.
#
# The hostname must be a fully qualified domain name that is NOT the same as
# any domain you plan to host on the server (cPanel refuses to add a domain
# that matches the hostname). Something like server.example.com. The installer
# checks this before it does anything expensive, and so does this script.
#
# cPanel serves WHM on 2087 and cPanel on 2083, both HTTPS with a self-signed
# certificate until AutoSSL replaces it once the hostname resolves. Nothing is
# added in front of it -- cPanel manages ports 80, 443, 2083 and 2087 itself,
# and a second web server would fight it.
#
# Ports: deliberately not touched. cPanel ships its own firewall expectations
# across mail, DNS, FTP and its four web ports, and hosts commonly add CSF on
# top. An allow list written here would fight all of that.
#
# Upstream: https://cpanel.net
# Installer: https://securedownloads.cpanel.net/latest
set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/storizagroup/storiza-provision-scripts/main/lib/provision.sh \
	-o /tmp/storiza-lib.sh && . /tmp/storiza-lib.sh

storiza_start "cPanel" \
	"Reading your answers" \
	"Checking the server is empty" \
	"Setting the hostname" \
	"Installing cPanel & WHM"

step
SERVER_HOSTNAME=$(need '.inputs.server_hostname')
IP_ADDRESS=$(answer '.vps.ip.address')
case "$SERVER_HOSTNAME" in
	*.*.*) ;;
	*) fail "'${SERVER_HOSTNAME}' is not a fully qualified name -- cPanel needs something like server.example.com." ;;
esac

step
# cPanel installs on a bare machine and manages the stack itself. Anything we
# add first -- a web server, a database -- makes the install fail.
for blocker in nginx apache2 mysql-server mariadb-server; do
	if dpkg -l "$blocker" 2> /dev/null | grep -q "^ii"; then
		fail "${blocker} is already installed, and cPanel requires a clean server."
	fi
done
pkg curl perl

step
hostnamectl set-hostname "$SERVER_HOSTNAME"
grep -q "$SERVER_HOSTNAME" /etc/hosts \
	|| echo "${IP_ADDRESS} ${SERVER_HOSTNAME} ${SERVER_HOSTNAME%%.*}" >> /etc/hosts

step
echo "[storiza] running the cPanel installer -- this takes 30-60 minutes"
cd /home
curl -fsSL -o latest https://securedownloads.cpanel.net/latest
sh latest || fail "The cPanel installer did not finish."
rm -f /home/latest

credentials <<CREDS
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

echo "[storiza] WHM ready at https://${IP_ADDRESS}:2087 -- sign in as root"
