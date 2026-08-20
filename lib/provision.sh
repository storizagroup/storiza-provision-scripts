#!/usr/bin/env bash
#
# The Storiza provisioning library. Every script in this repository sources it
# as its first act:
#
#     curl -fsSL https://raw.githubusercontent.com/storizagroup/storiza-provision-scripts/main/lib/provision.sh \
#         -o /tmp/storiza-lib.sh && . /tmp/storiza-lib.sh
#
# It does two things: it reports progress, and it owns the parts every
# installer repeats.
#
# -- The protocol ----------------------------------------------------------
#
# Four files under /var/lib/storiza. Storiza reads them over the QEMU guest
# agent while the install runs, so the customer watches real progress instead
# of a spinner:
#
#   provision.json  the order and the answers typed at checkout  (Storiza writes)
#   steps           [{"id":1,"name":"Installing system dependencies"}, ...]
#                   written once, before anything is installed
#   state           {"state":"running","current_step":3,"failure_reason":null}
#                   rewritten atomically at every step
#   logs            everything this script printed, stdout and stderr both
#
# state is one of waiting / running / completed / failed. `waiting` is written
# by Storiza before the machine boots; this library only moves it forward, and
# always reaches a terminal value -- the EXIT trap sees to that, so a crashed
# install reports `failed` rather than hanging on `running` forever.
#
# -- The rest --------------------------------------------------------------
#
#   answer/need     read the payload, no jq boilerplate
#   pkg             apt, quiet and non-interactive
#   self_signed     a certificate for an IP or a name; sets SSL_CERT, SSL_KEY,
#                   CERT_TRUSTED and CERT_NOTE
#   certbot_try     upgrade it to Let's Encrypt, without failing the install
#   serve_https     both of those plus an nginx vhost in front of a local port
#   allow_ports     refuse everything except these
#   deny_ports      close these, leave the rest alone
#   credentials     the /root/<product>-credentials.md file, chmod 600
#
set -euo pipefail

STORIZA_DIR=${STORIZA_DIR:-/var/lib/storiza}
PROVISION_DATA=${PROVISION_DATA:-$STORIZA_DIR/provision.json}

# nginx reads these at every boot for years -- that is configuration, so they
# do not travel with the throwaway state above.
STORIZA_SSL=${STORIZA_SSL:-/etc/ssl/storiza}

_NAME=""
_STEPS=()
_STEP=0
_FAIL=""
_DENIED=""

# -- protocol --------------------------------------------------------------

# JSON-escape a string. Step names are ours, but a failure reason can carry a
# quote from a command that died.
_esc() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'
}

# Written through a rename, so a poller can never read a half-written file.
_state() {
	printf '{"state":"%s","current_step":%s,"failure_reason":%s}\n' "$1" "$2" "$3" \
		> "$STORIZA_DIR/.state.new"
	chmod 600 "$STORIZA_DIR/.state.new"
	mv -f "$STORIZA_DIR/.state.new" "$STORIZA_DIR/state"
}

_finish() {
	local code=$1 why
	trap - EXIT
	if [ "$code" -eq 0 ]; then
		echo "[storiza] $_NAME provisioning finished $(date -Is)"
		_state completed "$_STEP" null
	else
		why=${_FAIL:-"${_STEPS[$((_STEP - 1))]:-Provisioning} failed (exit $code) -- see the log"}
		echo "[storiza] FAILED: $why" >&2
		_state failed "$_STEP" "\"$(_esc "$why")\""
	fi
}

# storiza_start "Coolify" "First step" "Second step" ...
storiza_start() {
	_NAME=$1
	shift
	_STEPS=("$@")

	mkdir -p "$STORIZA_DIR"
	chmod 700 "$STORIZA_DIR"
	: > "$STORIZA_DIR/logs"
	chmod 600 "$STORIZA_DIR/logs"

	local i=0 s
	{
		printf '['
		for s in ${_STEPS[@]+"${_STEPS[@]}"}; do
			i=$((i + 1))
			[ "$i" -gt 1 ] && printf ','
			printf '{"id":%d,"name":"%s"}' "$i" "$(_esc "$s")"
		done
		printf ']\n'
	} > "$STORIZA_DIR/steps"
	chmod 600 "$STORIZA_DIR/steps"

	_state running 0 null
	trap '_finish $?' EXIT

	# From here on, everything printed lands in the log as well as on the
	# console where cloud-init keeps it. Started before the first apt call on
	# purpose: a machine that cannot reach the mirrors should say so.
	exec > >(tee -a "$STORIZA_DIR/logs") 2>&1
	echo "[storiza] $_NAME provisioning started $(date -Is)"

	# ponytail: until the VPS worker writes the payload to the new location,
	# accept the old one. Delete this once storiza-api ships that change.
	[ -r "$PROVISION_DATA" ] || [ ! -r /etc/storiza/provision.json ] \
		|| PROVISION_DATA=/etc/storiza/provision.json

	[ -r "$PROVISION_DATA" ] || fail "The provisioning payload is missing -- nothing to install."
}

# Advance to the next declared step. Takes no argument: the order lives in the
# list given to storiza_start and nowhere else.
step() {
	_STEP=$((_STEP + 1))
	_state running "$_STEP" null
	printf '\n[storiza] (%d/%d) %s\n' "$_STEP" "${#_STEPS[@]}" "${_STEPS[$((_STEP - 1))]:-}"
}

# Stop, with a reason the customer will read in their dashboard. Write it for
# them, not for us: "admin_email is required", not "jq returned empty".
fail() {
	_FAIL=$1
	exit 1
}

# -- payload ---------------------------------------------------------------

_jq() {
	command -v jq > /dev/null 2>&1 || pkg jq
	jq "$@"
}

# answer '.inputs.panel_domain'  -- empty when it was not answered
answer() {
	_jq -r "$1 // empty" "$PROVISION_DATA"
}

# need '.inputs.admin_email'     -- or stop, naming the answer that is missing
need() {
	local v
	v=$(answer "$1")
	[ -n "$v" ] || fail "${1##*.} is required, and the order did not carry one."
	printf '%s' "$v"
}

# -- install ---------------------------------------------------------------

pkg() {
	export DEBIAN_FRONTEND=noninteractive
	[ -n "${_APT_UPDATED:-}" ] || { apt-get update -qq && _APT_UPDATED=1; }
	apt-get install -y -qq "$@" > /dev/null
}

# Call after adding an apt repository, so the next pkg re-reads the lists.
pkg_refresh() { _APT_UPDATED=""; }

# Stop early rather than half-install on a distribution the vendor rejects.
#     supported_ubuntu 22.04 24.04 26.04
supported_ubuntu() {
	. /etc/os-release
	case " $* " in
		*" ${VERSION_ID:-none} "*) return 0 ;;
	esac
	fail "$_NAME supports Ubuntu $*, and this server runs ${PRETTY_NAME:-an unknown system}."
}

# -- https -----------------------------------------------------------------

# self_signed <host> [also this IP]
#
# A certificate for the address the customer will actually type. Sets
# SSL_CERT, SSL_KEY and CERT_NOTE.
self_signed() {
	local host=$1 san
	pkg openssl
	case "$host" in
		*[a-zA-Z]*) san="DNS:$host" ;;
		*) san="IP:$host" ;;
	esac
	[ -n "${2:-}" ] && [ "$2" != "$host" ] && san="${san},IP:$2"

	mkdir -p "$STORIZA_SSL"
	openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -sha256 \
		-keyout "$STORIZA_SSL/self.key" -out "$STORIZA_SSL/self.crt" \
		-subj "/CN=${host}" -addext "subjectAltName=${san}" 2> /dev/null
	chmod 600 "$STORIZA_SSL/self.key"

	SSL_CERT="$STORIZA_SSL/self.crt"
	SSL_KEY="$STORIZA_SSL/self.key"
	CERT_TRUSTED=no
	CERT_NOTE="self-signed -- the browser warns once"
}

# certbot_try <domain> [email]
#
# A domain whose A record does not point here yet is the ordinary case at
# provisioning time, so this never fails the install: it leaves the
# self-signed certificate and tells the customer the one command to run later.
# Updates CERT_NOTE when it succeeds. Call it once the vhost exists.
certbot_try() {
	local domain=$1 email=${2:-} reg=--register-unsafely-without-email
	[ -n "$domain" ] || return 0
	[ -z "$email" ] || reg="-m $email"

	pkg certbot python3-certbot-nginx
	echo "[storiza] asking Let's Encrypt for a certificate for ${domain}"
	# shellcheck disable=SC2086
	if certbot --nginx -d "$domain" --non-interactive --agree-tos $reg \
		--redirect --keep-until-expiring; then
		SSL_CERT="/etc/letsencrypt/live/${domain}/fullchain.pem"
		SSL_KEY="/etc/letsencrypt/live/${domain}/privkey.pem"
		CERT_TRUSTED=yes
		CERT_NOTE="Let's Encrypt, renews itself"
	else
		echo "[storiza] ${domain} does not resolve here yet -- keeping the self-signed certificate"
		echo "[storiza] once its A record points at this server, run: certbot --nginx -d ${domain}"
	fi
	systemctl reload nginx || true
}

# serve_https <app port> [public port] [domain]
#
# Puts nginx in front of something already listening on localhost: TLS
# terminated on the public port (443 unless you say otherwise), proxying to
# the app port. With a domain it also redirects 80 and asks Let's Encrypt for
# a real certificate; without one the self-signed certificate stands, because
# a browser warning beats a password crossing the network in the clear.
#
#     serve_https 23333            -- the app on 23333, published on 443
#     serve_https 8000 8443        -- the app on 8000, published on 8443
#                                     because 80 and 443 belong to its own proxy
#
# Sets PANEL_URL and CERT_NOTE for the credentials file.
serve_https() {
	local app=$1 public=${2:-443} domain=${3:-} ip conf=/etc/nginx/sites-available/storiza.conf

	ip=$(answer '.vps.ip.address')
	pkg nginx
	self_signed "${domain:-$ip}" "$ip"

	: > "$conf"

	# Port 80 only when the panel is on 443. A panel parked on 8443 is there
	# because something else -- Traefik, usually -- owns 80 and 443.
	if [ "$public" = 443 ]; then
		cat >> "$conf" <<NGINX
server {
    listen 80;
    server_name ${domain:-_};

    # Left reachable so an http-01 challenge can be answered later.
    location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

NGINX
	fi

	cat >> "$conf" <<NGINX
server {
    # No http2 and no [::] on purpose: the directive spelling changed in nginx
    # 1.25, and a host with IPv6 off cannot bind [::]. Either one would fail
    # the config test on an older nginx and take the whole install down.
    listen ${public} ssl;
    server_name ${domain:-_};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 2048m;

    location / {
        proxy_pass http://127.0.0.1:${app};
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

	mkdir -p /var/www/html
	rm -f /etc/nginx/sites-enabled/default
	ln -sf "$conf" /etc/nginx/sites-enabled/storiza.conf
	nginx -t
	systemctl enable --now nginx
	systemctl restart nginx

	PANEL_URL="https://${domain:-$ip}"
	[ "$public" = 443 ] || PANEL_URL="${PANEL_URL}:${public}"

	[ -n "$domain" ] && certbot_try "$domain"
	return 0
}

# -- firewall --------------------------------------------------------------
#
# allow_ports 80/tcp 443/tcp 8443/tcp
#     Refuse everything else. For a product whose port list is short and
#     known.
#
# deny_ports 8000/tcp
#     Close these, leave everything else open. For a product whose customer
#     will be opening ports of their own -- game servers, mail -- where an
#     allow list would only get in the way.
#
# Using both together is normal, and on a Docker host it is the only thing
# that works: Docker's DNAT rules run before ufw's filter chain, so a
# published container port ignores the allow list completely. deny_ports
# writes the DOCKER-USER rule that actually closes it, into ufw's after.rules
# so it survives a reboot. Call these after the product is installed, so
# Docker is there to be gated.
#
# SSH always stays open. Locking the customer out of the machine they paid for
# is worse than any port being reachable.

_ufw() {
	command -v ufw > /dev/null 2>&1 || pkg ufw
	[ -z "${_UFW_READY:-}" ] || return 0

	local ssh_port
	ssh_port=$(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2> /dev/null \
		| awk '/^[[:space:]]*[Pp]ort[[:space:]]+[0-9]+/ { print $2; exit }')

	ufw --force reset > /dev/null
	ufw default allow outgoing > /dev/null
	ufw default allow incoming > /dev/null
	ufw allow "${ssh_port:-22}/tcp" > /dev/null
	_UFW_READY=1
}

allow_ports() {
	local p
	_ufw
	ufw default deny incoming > /dev/null
	for p in "$@"; do ufw allow "$p" > /dev/null; done
	ufw --force enable > /dev/null
	echo "[storiza] firewall: only $* and SSH accept connections"
}

deny_ports() {
	local p port proto ext
	_ufw
	ext=$(_ext_if)
	for p in "$@"; do
		port=${p%%/*}
		proto=tcp
		case "$p" in */*) proto=${p##*/} ;; esac
		# Scoped to the interface facing the internet rather than to the port
		# outright: a container reaching the host's MariaDB over the Docker
		# bridge arrives on the same port and has every right to.
		if [ -n "$ext" ]; then
			ufw deny in on "$ext" to any port "$port" proto "$proto" > /dev/null
		else
			ufw deny "$p" > /dev/null
		fi
		_DENIED="$_DENIED $p"
	done
	ufw --force enable > /dev/null
	_docker_gate
	echo "[storiza] firewall: $* closed to the internet"
}

# The interface the default route leaves by -- what "from outside" means here.
_ext_if() {
	ip route get 1.1.1.1 2> /dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

_docker_gate() {
	command -v docker > /dev/null 2>&1 || return 0

	local f=${UFW_AFTER_RULES:-/etc/ufw/after.rules} ext p port proto
	ext=$(_ext_if)
	[ -n "$ext" ] || return 0

	sed -i '/^# BEGIN STORIZA/,/^# END STORIZA/d' "$f"
	{
		echo "# BEGIN STORIZA -- a published container port is not filtered by the"
		echo "# rules above, because Docker's DNAT runs first. DOCKER-USER is the"
		echo "# hook it leaves for exactly this."
		echo "*filter"
		echo ":DOCKER-USER - [0:0]"
		for p in $_DENIED; do
			port=${p%%/*}
			proto=tcp
			case "$p" in */*) proto=${p##*/} ;; esac
			echo "-A DOCKER-USER -i ${ext} -p ${proto} --dport ${port} -j DROP"
		done
		echo "-A DOCKER-USER -j RETURN"
		echo "COMMIT"
		echo "# END STORIZA"
	} >> "$f"
	ufw reload > /dev/null
}

# -- credentials -----------------------------------------------------------

# credentials <<EOF ... EOF
#
# Writes /root/<product>-credentials.md, chmod 600. Secrets go here and only
# here -- never to stdout, which cloud-init keeps in a world-readable log.
credentials() {
	local f
	f="/root/$(printf '%s' "$_NAME" | tr '[:upper:] ' '[:lower:]-')-credentials.md"
	cat > "$f"
	cat >> "$f" <<FOOT

> Keep this file secure. Consider deleting it once the password is stored
> somewhere safe.
FOOT
	chmod 600 "$f"
	echo "[storiza] credentials written to $f"
}
