#!/bin/bash
###############################################################################
#  Pterodactyl Panel + Wings -- Storiza provision script
#  -------------------------------------------------------------------
#  Run once by cloud-init while a Storiza VPS first boots. The customer's
#  answers arrive in a file, never as arguments:
#
#      /etc/storiza/provision.json   { "vps": {...}, "inputs": {...} }
#
#  Inputs consumed (declared on the `pterodactyl` VPS template):
#      inputs.admin_email     -- panel administrator, required
#      inputs.admin_password  -- panel administrator's password, required
#      inputs.panel_domain    -- optional; the panel answers on the IP without it
#
#  What it installs:
#  * Panel (latest 1.x) with all dependencies
#  * Wings (latest 1.x)
#  * The first admin user
#  * An Application API key via a temporary artisan command
#    (the ONLY reliable method -- direct DB inserts don't work because
#     Pterodactyl/Sanctum hashes tokens with SHA-256)
#  * Location + Node + Allocations via the API
#  * Node config at /etc/pterodactyl/config.yml, services started and enabled
#
#  Tested on: Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12
#  Runs as root, with zero interactive prompts.
###############################################################################

set -euo pipefail
trap 'echo -e "\033[0;31m[✗] Script failed at line $LINENO (exit code $?)\033[0m" >&2
for _d in /var/www/html /var/www/pterodactyl/public; do
    [ -d "$_d" ] && echo "FAILED" > "$_d/install-status.txt" 2>/dev/null
done' ERR

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — Edit these before running
# ─────────────────────────────────────────────────────────────────────────────
DB_ROOT_PASS="R00t_$(openssl rand -hex 8)"
DB_PANEL_PASS="Pt3r0_$(openssl rand -hex 8)"
DB_PANEL_USER="pterodactyl"
DB_PANEL_NAME="panel"

APP_URL=""                               # Leave empty to auto-detect IP
TIMEZONE="UTC"

# Where the self-signed certificate lives when there is no domain to get a
# real one for. The panel is HTTPS either way -- a game panel hands out
# passwords and API keys, and plaintext on a shared network is not an option.
SELF_SIGNED_DIR="/etc/pterodactyl/ssl"

NODE_NAME="node-01"
LOCATION_SHORT="dc-1"
LOCATION_LONG="Datacenter 1"

WINGS_PORT=8080
SFTP_PORT=2022

# Memory / disk reported by node (0 = auto-detect)
NODE_MEMORY_MB=0
NODE_DISK_MB=0

# ─────────────────────────────────────────────────────────────────────────────
# COLORS
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING — All output goes to both terminal AND log file
# ─────────────────────────────────────────────────────────────────────────────
LOG_FILE="/root/pterodactyl-install.log"

# Write a clean (no ANSI) timestamped line to the log file
_log_to_file() {
    local clean
    clean=$(echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g')
    echo "$(date '+%Y-%m-%d %H:%M:%S') $clean" >> "$LOG_FILE"
}

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; _log_to_file "[ERR]  $*"; exit 1; }
step() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

# Initialize log file
echo "" > "$LOG_FILE"
echo "===============================================================================" >> "$LOG_FILE"
echo "  Pterodactyl Panel — Installation Log" >> "$LOG_FILE"
echo "  Started: $(date '+%Y-%m-%d %H:%M:%S %Z')" >> "$LOG_FILE"
echo "  Host:    $(hostname)" >> "$LOG_FILE"
echo "  OS:      $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)" >> "$LOG_FILE"
echo "  Kernel:  $(uname -r)" >> "$LOG_FILE"
echo "===============================================================================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Capture ALL command output (stdout + stderr) to the log file too.
# This uses process substitution: output still appears on the terminal,
# but a color-stripped, timestamped copy is appended to the log file.
exec > >(while IFS= read -r line; do
    printf '%s\n' "$line"
    printf '%s %s\n' "$(date '+%H:%M:%S')" "$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g')" >> "$LOG_FILE"
done) 2>&1

chmod 600 "$LOG_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT
# ─────────────────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "This script must be run as root."

export DEBIAN_FRONTEND=noninteractive

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"
else
    err "Unsupported OS — /etc/os-release not found."
fi

case "$OS_ID" in
    ubuntu|debian) ;;
    *) err "Unsupported OS: $OS_ID. Only Ubuntu/Debian supported." ;;
esac

# -----------------------------------------------------------------------------
# THE CUSTOMER'S ANSWERS
#
# Read from a file so nothing typed by a customer is ever part of a command
# line. `// empty` turns an absent optional answer into "" rather than "null".
# -----------------------------------------------------------------------------
step "Reading provisioning payload"

PROVISION_DATA="${PROVISION_DATA:-/etc/storiza/provision.json}"
[ -r "$PROVISION_DATA" ] || err "$PROVISION_DATA not found -- nothing to install."

command -v jq >/dev/null 2>&1 || apt-get install -y jq >/dev/null 2>&1 \
    || err "jq is required to read $PROVISION_DATA."

_answer() { jq -r "$1 // empty" "$PROVISION_DATA"; }

ADMIN_EMAIL=$(_answer '.inputs.admin_email')
ADMIN_PASSWORD=$(_answer '.inputs.admin_password')
PANEL_DOMAIN=$(_answer '.inputs.panel_domain')
ASSIGNED_IP=$(_answer '.vps.ip.address')

# Fixed rather than asked: one administrator is created and the customer
# renames it from inside the panel.
ADMIN_USER="admin"
ADMIN_FIRSTNAME="admin"
ADMIN_LASTNAME="istrator"

[ -n "$ADMIN_EMAIL" ]    || err "inputs.admin_email is missing from $PROVISION_DATA."
[ -n "$ADMIN_PASSWORD" ] || err "inputs.admin_password is missing from $PROVISION_DATA."

# A domain only becomes the panel's URL here; HTTPS waits until its DNS has
# actually propagated, because certbot failing would abort the whole install.
if [ -n "$PANEL_DOMAIN" ]; then
    PANEL_FQDN="$PANEL_DOMAIN"
    APP_URL="https://${PANEL_DOMAIN}"
    log "Panel domain: $PANEL_DOMAIN"
else
    log "No panel domain answered -- the panel will answer on the server IP"
fi

log "Panel administrator: $ADMIN_EMAIL"

# Auto-detect public IP
step "Detecting public IP"
PUBLIC_IP="$ASSIGNED_IP"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP=$(curl -4 -s --max-time 5 https://ifconfig.me \
         || curl -4 -s --max-time 5 https://api.ipify.org \
         || curl -4 -s --max-time 5 https://icanhazip.com \
         || hostname -I | awk '{print $1}')
log "Public IP: $PUBLIC_IP"

if [ -z "$APP_URL" ]; then
    APP_URL="https://${PUBLIC_IP}"
    PANEL_FQDN="$PUBLIC_IP"
fi

# Auto-detect memory / disk
if [ "$NODE_MEMORY_MB" -eq 0 ]; then
    NODE_MEMORY_MB=$(free -m | awk '/^Mem:/{print $2}')
fi
if [ "$NODE_DISK_MB" -eq 0 ]; then
    NODE_DISK_MB=$(df -BM / | awk 'NR==2{gsub("M",""); print $4}')
fi

log "Node will report ${NODE_MEMORY_MB} MB RAM, ${NODE_DISK_MB} MB disk"

###############################################################################
# 1. SYSTEM DEPENDENCIES
###############################################################################
step "Installing system dependencies"

apt-get update -yq
apt-get upgrade -yq
apt-get install -yq \
    software-properties-common curl apt-transport-https ca-certificates gnupg \
    tar unzip git redis-server mariadb-server nginx certbot \
    python3-certbot-nginx jq

# ── Deploy install status page immediately (nginx is now running) ──
rm -f /var/www/html/index.nginx-debian.html
cat > /var/www/html/index.html <<'STATUSHTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Pterodactyl — Installing...</title>
<style>
:root {
  --bg: #0b1120; --sf: #131c31; --bd: #1e2d4a; --tx: #e2e8f0;
  --mt: #64748b; --ac: #38bdf8; --ok: #22c55e; --wr: #f59e0b; --er: #ef4444;
}
*, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
html, body { height: 100%; }
body {
  font-family: 'Inter', 'Segoe UI', system-ui, -apple-system, sans-serif;
  background: var(--bg); color: var(--tx);
  display: flex; flex-direction: column; overflow: hidden;
}
.hdr { text-align: center; padding: 2rem 1rem 1.2rem; flex-shrink: 0; }
.spin {
  width: 50px; height: 50px;
  border: 3px solid var(--bd); border-top-color: var(--ac);
  border-radius: 50%; animation: spin 1s linear infinite;
  margin: 0 auto 1rem;
}
@keyframes spin { to { transform: rotate(360deg); } }
.hdr h1 { font-size: 1.4rem; font-weight: 700; color: #f8fafc; }
.sub { color: var(--mt); font-size: 0.9rem; margin-top: 0.35rem; }
.log-wrap {
  flex: 1; display: flex; flex-direction: column;
  margin: 0 auto; width: min(92%, 960px); min-height: 0;
}
.log-bar {
  background: var(--sf); padding: 0.55rem 1rem;
  border-radius: 0.5rem 0.5rem 0 0;
  border: 1px solid var(--bd); border-bottom: none;
  font-size: 0.8rem; color: var(--mt);
  display: flex; justify-content: space-between; align-items: center;
  flex-shrink: 0;
}
.live { display: flex; align-items: center; }
.dot {
  width: 7px; height: 7px; background: var(--ok);
  border-radius: 50%; margin-right: 0.5rem;
  animation: pulse 2s infinite;
}
@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.2} }
#log {
  background: #060b16;
  border: 1px solid var(--bd); border-top: none;
  border-radius: 0 0 0.5rem 0.5rem;
  padding: 0.75rem 1rem;
  font-family: 'JetBrains Mono','Fira Code','Cascadia Code','Consolas',monospace;
  font-size: 0.76rem; line-height: 1.7;
  overflow-y: auto; flex: 1; min-height: 0;
  white-space: pre-wrap; word-break: break-word;
  color: #8892a8;
}
.ft {
  padding: 1rem; text-align: center;
  color: var(--mt); font-size: 0.8rem; flex-shrink: 0;
}
.ov {
  display: none; position: fixed; inset: 0;
  background: rgba(11,17,32,0.96); z-index: 100;
  flex-direction: column; align-items: center; justify-content: center;
}
.ov.on { display: flex; }
.ov-ic {
  width: 76px; height: 76px; border-radius: 50%;
  display: flex; align-items: center; justify-content: center;
  margin-bottom: 1.3rem; animation: pop 0.4s ease-out;
}
@keyframes pop { 0%{transform:scale(0)} 70%{transform:scale(1.1)} 100%{transform:scale(1)} }
.ov-ic.ok { background: var(--ok); }
.ov-ic.er { background: var(--er); }
.ov-ic svg {
  width: 36px; height: 36px; stroke: #fff; stroke-width: 2.5;
  fill: none; stroke-linecap: round; stroke-linejoin: round;
}
.ov h2 { font-size: 1.35rem; font-weight: 700; color: #f8fafc; margin-bottom: 0.4rem; }
.ov p  { color: var(--mt); font-size: 0.92rem; }
.c-ok   { color: #4ade80; }
.c-warn { color: #fbbf24; }
.c-err  { color: #f87171; }
.c-step { color: #38bdf8; font-weight: 600; }
.c-ts   { color: #475569; }
</style>
</head>
<body>
<div class="hdr">
  <div class="spin" id="spinner"></div>
  <h1>Pterodactyl Panel</h1>
  <p class="sub" id="status">Installation in progress &mdash; please wait&hellip;</p>
</div>
<div class="log-wrap">
  <div class="log-bar">
    <span class="live"><span class="dot"></span>Live Install Log</span>
    <span id="lc">0 lines</span>
  </div>
  <pre id="log">Waiting for log output...</pre>
</div>
<div class="ft">This page updates automatically. Do not close this window or restart the server.</div>
<div class="ov" id="ov-ok">
  <div class="ov-ic ok"><svg viewBox="0 0 24 24"><polyline points="20 6 9 17 4 12"/></svg></div>
  <h2>Installation Complete!</h2>
  <p>Redirecting to panel in <span id="cd">10</span>s&hellip;</p>
</div>
<div class="ov" id="ov-er">
  <div class="ov-ic er"><svg viewBox="0 0 24 24"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></div>
  <h2>Installation Failed</h2>
  <p>Check the server terminal for error details.</p>
</div>
<script>
(function(){
  var logEl=document.getElementById('log'),lcEl=document.getElementById('lc'),
      stEl=document.getElementById('status'),lastL=0;
  function E(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
  function color(t){return t.split('\n').map(function(r){
    var m=r.match(/^(\d{2}:\d{2}:\d{2})\s(.*)/),ts='',x=r;
    if(m){ts='<span class="c-ts">'+m[1]+'</span> ';x=m[2]}
    if(/\[\u2713\]|EGG_OK|:PASS/.test(x)) return ts+'<span class="c-ok">'+E(x)+'</span>';
    if(/\[!\]|SKIP|WARN/.test(x))  return ts+'<span class="c-warn">'+E(x)+'</span>';
    if(/\[\u2717\]|FAIL|ERR/.test(x))  return ts+'<span class="c-err">'+E(x)+'</span>';
    if(/\u2501\u2501\u2501/.test(x))    return ts+'<span class="c-step">'+E(x)+'</span>';
    return ts+E(x);
  }).join('\n')}
  function findStep(ls){for(var i=ls.length-1;i>=0;i--)
    if(/\u2501\u2501\u2501/.test(ls[i])){var s=ls[i].replace(/\u2501/g,'').trim();if(s)return s}return null}
  function showDone(){
    document.getElementById('spinner').style.display='none';
    stEl.textContent='Installation complete!';
    document.getElementById('ov-ok').classList.add('on');
    var c=10,iv=setInterval(function(){c--;document.getElementById('cd').textContent=c;
      if(c<=0){clearInterval(iv);location.href='/'}},1000);
  }
  function showFail(){
    document.getElementById('spinner').style.display='none';
    stEl.textContent='Installation failed';
    document.getElementById('ov-er').classList.add('on');
  }
  async function poll(){
    try{var r=await fetch('install-log.txt?_='+Date.now());if(r.ok){var t=await r.text();
      if(t.length!==lastL){lastL=t.length;logEl.innerHTML=color(t);
        lcEl.textContent=t.split('\n').length+' lines';logEl.scrollTop=logEl.scrollHeight;
        var s=findStep(t.split('\n'));if(s)stEl.textContent=s}}}catch(e){}
    try{var s=await fetch('install-status.txt?_='+Date.now());if(s.ok){var v=(await s.text()).trim();
      if(v==='COMPLETE'){showDone();return}if(v==='FAILED'){showFail();return}}}catch(e){}
    setTimeout(poll,2000);
  }
  poll();
})();
</script>
</body>
</html>
STATUSHTML

echo "INSTALLING" > /var/www/html/install-status.txt
cp -f "$LOG_FILE" /var/www/html/install-log.txt 2>/dev/null || true
chmod 644 /var/www/html/index.html /var/www/html/install-status.txt /var/www/html/install-log.txt 2>/dev/null

# Background: sync log file to web directory every 2 seconds
touch /tmp/.ptero_install_running
(
    while [ -f /tmp/.ptero_install_running ]; do
        for d in /var/www/html /var/www/pterodactyl/public; do
            [ -d "$d" ] || continue
            cp -f "$LOG_FILE" "$d/install-log.txt" 2>/dev/null
            chmod 644 "$d/install-log.txt" 2>/dev/null
        done
        sleep 2
    done
) &
LOG_SYNC_PID=$!

log "Install status page: https://${PUBLIC_IP}/ (port 80 redirects there)"

# PHP repository
if [ "$OS_ID" = "ubuntu" ]; then
    add-apt-repository -y ppa:ondrej/php
elif [ "$OS_ID" = "debian" ]; then
    curl -sSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
    dpkg -i /tmp/debsuryorg-archive-keyring.deb
    echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-archive.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
        > /etc/apt/sources.list.d/sury-php.list
fi

apt-get update -yq
apt-get install -yq \
    php8.3 php8.3-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip,intl,readline,common,opcache}

# Composer
export HOME=/root
export COMPOSER_HOME=/root/.composer
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
log "PHP & Composer installed"

###############################################################################
# 2. MARIADB
###############################################################################
step "Configuring MariaDB"

systemctl enable --now mariadb

# Secure installation (non-interactive)
mysql -u root <<MYSQL_SECURE
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
MYSQL_SECURE

# Create panel database + user
mysql -u root -p"${DB_ROOT_PASS}" <<MYSQL_PANEL
CREATE DATABASE IF NOT EXISTS \`${DB_PANEL_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_PANEL_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PANEL_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_PANEL_NAME}\`.* TO '${DB_PANEL_USER}'@'127.0.0.1' WITH GRANT OPTION;

-- Wings needs a user that can create per-server databases
CREATE USER IF NOT EXISTS '${DB_PANEL_USER}'@'%' IDENTIFIED BY '${DB_PANEL_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${DB_PANEL_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
MYSQL_PANEL

log "MariaDB configured"

###############################################################################
# 3. PANEL INSTALLATION
###############################################################################
step "Installing Pterodactyl Panel"

mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/
rm panel.tar.gz

cp .env.example .env

composer install --no-dev --optimize-autoloader --no-interaction

php artisan key:generate --force --no-interaction

php artisan p:environment:setup \
    --author="$ADMIN_EMAIL" \
    --url="$APP_URL" \
    --timezone="$TIMEZONE" \
    --cache=redis \
    --session=redis \
    --queue=redis \
    --redis-host=127.0.0.1 \
    --redis-pass="" \
    --redis-port=6379 \
    --settings-ui=true \
    --telemetry=false \
    --no-interaction

php artisan p:environment:database \
    --host=127.0.0.1 \
    --port=3306 \
    --database="$DB_PANEL_NAME" \
    --username="$DB_PANEL_USER" \
    --password="$DB_PANEL_PASS" \
    --no-interaction

php artisan migrate --seed --force --no-interaction

php artisan p:user:make \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USER" \
    --name-first="$ADMIN_FIRSTNAME" \
    --name-last="$ADMIN_LASTNAME" \
    --password="$ADMIN_PASSWORD" \
    --admin=1 \
    --no-interaction

chown -R www-data:www-data /var/www/pterodactyl/*

(crontab -l -u www-data 2>/dev/null || true; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -u www-data -

cat > /etc/systemd/system/pteroq.service <<'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now pteroq
log "Panel installed"

###############################################################################
# 4. NGINX
###############################################################################
step "Configuring Nginx"

rm -f /etc/nginx/sites-enabled/default

# A certificate has to exist before nginx will start with a 443 block, and
# Let's Encrypt cannot issue one for an IP address -- so every server gets a
# self-signed certificate now, and a real one replaces it below if a domain
# was answered and its DNS already points here.
mkdir -p "$SELF_SIGNED_DIR"
if [ ! -s "$SELF_SIGNED_DIR/self.crt" ]; then
    SAN="IP:${PUBLIC_IP}"
    [ -n "$PANEL_DOMAIN" ] && SAN="DNS:${PANEL_DOMAIN},${SAN}"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -sha256 \
        -keyout "$SELF_SIGNED_DIR/self.key" -out "$SELF_SIGNED_DIR/self.crt" \
        -subj "/CN=${PANEL_FQDN}" -addext "subjectAltName=${SAN}" 2>/dev/null
    chmod 600 "$SELF_SIGNED_DIR/self.key"
    log "Self-signed certificate created for ${SAN}"
fi

SSL_CERT="$SELF_SIGNED_DIR/self.crt"
SSL_KEY="$SELF_SIGNED_DIR/self.key"
SSL_IS_TRUSTED="no"

cat > /etc/nginx/sites-available/pterodactyl.conf <<NGINX_CONF
server {
    listen 80;
    server_name ${PANEL_FQDN} _;

    # Left reachable so certbot's http-01 challenge can be answered later.
    location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    # No http2 and no [::] here on purpose: the directive spelling changed in
    # nginx 1.25 and a host with IPv6 off cannot bind [::], and either one
    # would fail the nginx config test and take the whole install down with it.
    listen 443 ssl;
    server_name ${PANEL_FQDN} _;

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;

    root /var/www/pterodactyl/public;
    index index.html index.htm index.php;
    charset utf-8;

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log off;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        # Without this Laravel builds asset URLs as http:// and the browser
        # blocks every one of them as mixed content.
        fastcgi_param HTTPS on;
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht { deny all; }
}
NGINX_CONF

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf

nginx -t
systemctl enable --now nginx
systemctl restart nginx

# A real certificate needs the domain's A record to already point here, which
# is not something we can wait for. If it is not ready the self-signed one
# stays and the customer runs certbot themselves -- the panel works either way.
if [ -n "$PANEL_DOMAIN" ]; then
    step "Requesting a Let's Encrypt certificate for ${PANEL_DOMAIN}"
    if certbot --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos \
        -m "$ADMIN_EMAIL" --redirect --keep-until-expiring; then
        SSL_CERT="/etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem"
        SSL_KEY="/etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem"
        SSL_IS_TRUSTED="yes"
        log "Certificate issued -- the panel is trusted by browsers"
    else
        warn "Let's Encrypt could not verify ${PANEL_DOMAIN} (DNS not pointing here yet?)."
        warn "Keeping the self-signed certificate. Once the A record resolves, run:"
        warn "  certbot --nginx -d ${PANEL_DOMAIN}"
    fi
    systemctl reload nginx || true
fi

systemctl restart php8.3-fpm
log "Nginx configured"

# ── Copy status page to panel public dir (nginx now serves from there) ──
cp -f /var/www/html/index.html /var/www/pterodactyl/public/index.html 2>/dev/null || true
cp -f /var/www/html/install-status.txt /var/www/pterodactyl/public/install-status.txt 2>/dev/null || true
cp -f "$LOG_FILE" /var/www/pterodactyl/public/install-log.txt 2>/dev/null || true
chmod 644 /var/www/pterodactyl/public/index.html /var/www/pterodactyl/public/install-status.txt /var/www/pterodactyl/public/install-log.txt 2>/dev/null || true

###############################################################################
# 5. INSTALL WINGS
###############################################################################
step "Installing Wings"

if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | bash
fi
systemctl enable --now docker

mkdir -p /etc/pterodactyl /var/lib/pterodactyl/{volumes,backups}
curl -Lo /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([ "$(uname -m)" = "x86_64" ] && echo "amd64" || echo "arm64")"
chmod u+x /usr/local/bin/wings

cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
log "Wings binary installed"

###############################################################################
# 6. CREATE APPLICATION API KEY
#    ─────────────────────────────────────────────────────────────────────
#    WHY A TEMPORARY ARTISAN COMMAND?
#    Pterodactyl stores API tokens as SHA-256 hashes (via Laravel Sanctum).
#    The plaintext is shown once at creation and NEVER stored. You cannot
#    reverse-engineer a working Bearer token from a DB row. Inserting
#    directly into the api_keys table (with encrypt() or hash_hmac())
#    always produces HTTP 401 because Sanctum's lookup does:
#      hash('sha256', $bearerToken)  →  compare to DB `token` column.
#    The ONLY way to get a valid token+hash pair is to go through the
#    model's save pipeline. That's what this command does.
###############################################################################
step "Creating Application API key"

cd /var/www/pterodactyl

cat > app/Console/Commands/AutoApiKey.php <<'PHPCMD'
<?php
namespace Pterodactyl\Console\Commands;

use Illuminate\Console\Command;
use Pterodactyl\Models\ApiKey;
use Pterodactyl\Models\User;
use Illuminate\Support\Str;
use Illuminate\Encryption\Encrypter;

class AutoApiKey extends Command
{
    protected $signature = 'p:auto:apikey';
    protected $description = 'Create and self-test an Application API key';

    public function handle(Encrypter $encrypter): int
    {
        $user = User::where('root_admin', true)->firstOrFail();

        $identLen = ApiKey::IDENTIFIER_LENGTH;

        // Check if KEY_LENGTH constant exists
        try {
            $tokenLen = ApiKey::KEY_LENGTH;
        } catch (\Throwable $e) {
            $tokenLen = 32;
        }

        $identifier = Str::random($identLen);
        $token = Str::random($tokenLen);

        $key = new ApiKey();
        $key->user_id = $user->id;
        $key->key_type = ApiKey::TYPE_APPLICATION;
        $key->identifier = $identifier;
        $key->token = $encrypter->encrypt($token);
        $key->memo = 'auto-install';
        foreach(['r_servers','r_nodes','r_allocations','r_users','r_locations','r_nests','r_eggs','r_database_hosts','r_server_databases'] as $perm) {
            $key->$perm = 3;  // 1=READ, 2=WRITE, 3=READ+WRITE
        }
        $key->save();

        // Simulate the EXACT middleware logic from AuthenticateKey.php
        $bearerToken = $identifier . $token;

        $mwIdentifier = substr($bearerToken, 0, $identLen);
        $mwToken = substr($bearerToken, $identLen);

        $dbKey = ApiKey::where('identifier', $mwIdentifier)
                       ->where('key_type', ApiKey::TYPE_APPLICATION)
                       ->first();

        if (!$dbKey) {
            fwrite(STDERR, "SELFTEST:FAIL:identifier_not_found\n");
            fwrite(STDERR, "SELFTEST:identifier={$mwIdentifier}\n");
            echo "FAIL";
            return 1;
        }

        $decrypted = $encrypter->decrypt($dbKey->token);

        if (hash_equals($decrypted, $mwToken)) {
            fwrite(STDERR, "SELFTEST:PASS\n");
            fwrite(STDERR, "SELFTEST:ident_len={$identLen}\n");
            fwrite(STDERR, "SELFTEST:token_len={$tokenLen}\n");
            fwrite(STDERR, "SELFTEST:bearer_len=" . strlen($bearerToken) . "\n");

            echo $bearerToken;
            return 0;
        } else {
            fwrite(STDERR, "SELFTEST:FAIL:token_mismatch\n");
            fwrite(STDERR, "SELFTEST:decrypted_len=" . strlen($decrypted) . "\n");
            fwrite(STDERR, "SELFTEST:mwToken_len=" . strlen($mwToken) . "\n");
            echo "FAIL";
            return 1;
        }
    }
}
PHPCMD

php artisan clear-compiled 2>/dev/null || true

# Run and show debug on stderr, capture token from stdout
ARTISAN_STDERR=$(php artisan p:auto:apikey --no-interaction 2>&1 1>/tmp/apikey_stdout.txt) || true
PANEL_API_KEY=$(cat /tmp/apikey_stdout.txt | tr -d '[:space:]')

# Show self-test results
echo "$ARTISAN_STDERR" | grep "SELFTEST:" | while read line; do
    log "  $line"
done || true

rm -f app/Console/Commands/AutoApiKey.php
php artisan clear-compiled 2>/dev/null || true

if [ "$PANEL_API_KEY" = "FAIL" ] || [ -z "$PANEL_API_KEY" ]; then
    err "API key self-test failed. See output above."
fi

log "Bearer token (${#PANEL_API_KEY} chars): ${PANEL_API_KEY:0:25}..."

# Verify via HTTP
sleep 2
systemctl restart nginx php8.3-fpm
sleep 3

API_URL="${APP_URL}/api/application"
WORKING_KEY=""

# The panel is called over its own hostname so Laravel sees the URL it expects,
# but resolved to this machine and with verification off: the domain's DNS may
# not point here yet, and the certificate may be the self-signed one.
API_HOST=${APP_URL#https://}
CURL=(curl -sk --resolve "${API_HOST}:443:127.0.0.1")

# Try both with and without ptla_ prefix
for prefix in "" "ptla_"; do
    TEST_KEY="${prefix}${PANEL_API_KEY}"
    HTTP_CODE=$("${CURL[@]}" -o /tmp/api_resp.json -w "%{http_code}" \
        "${API_URL}/users" \
        -H "Authorization: Bearer ${TEST_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json")

    RESP=$(cat /tmp/api_resp.json 2>/dev/null | head -c 300)

    if [ "$HTTP_CODE" = "200" ]; then
        WORKING_KEY="$TEST_KEY"
        log "HTTP 200 with prefix='${prefix:-none}'"
        break
    else
        warn "prefix='${prefix:-none}' → HTTP $HTTP_CODE: $RESP"
    fi
done

if [ -z "$WORKING_KEY" ]; then
    warn "Self-test PASSED but HTTP still fails."
    warn "Checking actual Panel version..."
    PANEL_VER=$(php artisan --version 2>/dev/null || echo "unknown")
    warn "Panel: $PANEL_VER"
    if grep -q "sanctum" config/auth.php 2>/dev/null; then
        warn "Sanctum detected in auth.php!"
    fi
    if [ -f "app/Http/Middleware/Api/AuthenticateKey.php" ]; then
        warn "AuthenticateKey middleware exists. Dumping key parts..."
        grep -n "substr\|IDENTIFIER_LENGTH\|decrypt\|hash_equals\|bearerToken\|ptla\|ptlc\|prefix" \
            app/Http/Middleware/Api/AuthenticateKey.php 2>/dev/null || true
    fi
    err "Cannot get API working. Create key manually at ${APP_URL}/admin/api"
fi

PANEL_API_KEY="$WORKING_KEY"
AUTH_HEADER="Authorization: Bearer ${PANEL_API_KEY}"

###############################################################################
# 7. API HELPER
###############################################################################
api_call() {
    local method="$1" endpoint="$2" data="${3:-}"
    local response http_code body
    for attempt in 1 2 3 4 5; do
        if [ -n "$data" ]; then
            response=$("${CURL[@]}" -w "\n%{http_code}" -X "$method" \
                "${API_URL}${endpoint}" \
                -H "$AUTH_HEADER" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                -d "$data")
        else
            response=$("${CURL[@]}" -w "\n%{http_code}" -X "$method" \
                "${API_URL}${endpoint}" \
                -H "$AUTH_HEADER" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json")
        fi
        http_code=$(echo "$response" | tail -1)
        body=$(echo "$response" | sed '$d')

        if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            echo "$body"
            return 0
        fi
        warn "Attempt $attempt: $method $endpoint → HTTP $http_code"
        warn "Response: $body"
        sleep 3
    done
    err "API failed after 5 attempts: $method $endpoint (HTTP $http_code)\nLast response: $body"
}

###############################################################################
# 8. CREATE LOCATION + NODE
###############################################################################
step "Creating location"

# Check if location already exists
EXISTING_LOCS=$(api_call GET "/locations") || true
LOCATION_ID=$(echo "$EXISTING_LOCS" | jq -r ".data[] | select(.attributes.short==\"${LOCATION_SHORT}\") | .attributes.id" 2>/dev/null)

if [ -n "$LOCATION_ID" ] && [ "$LOCATION_ID" != "null" ]; then
    log "Location already exists: ID $LOCATION_ID"
else
    LOCATION_RESPONSE=$(api_call POST "/locations" "{
        \"short\": \"${LOCATION_SHORT}\",
        \"long\": \"${LOCATION_LONG}\"
    }") || {
        err "Failed to create location. Check API response above."
    }
    if ! LOCATION_ID=$(echo "$LOCATION_RESPONSE" | jq -r '.attributes.id' 2>/dev/null) || [ -z "$LOCATION_ID" ] || [ "$LOCATION_ID" = "null" ]; then
        err "Failed to parse location ID from response: $LOCATION_RESPONSE"
    fi
    log "Location created: ID $LOCATION_ID"
fi

step "Creating node"

# Wings must match the panel's scheme: a page served over HTTPS is not allowed
# to open a plaintext websocket, so an http node means a dead console.
SCHEME="https"

# The node is addressed by the name its certificate is actually for. With a
# trusted certificate that is the domain; otherwise the IP, which the
# self-signed certificate carries as a SAN.
if [ "$SSL_IS_TRUSTED" = "yes" ]; then
    NODE_FQDN="$PANEL_DOMAIN"
else
    NODE_FQDN="$PUBLIC_IP"
fi

# Check if node already exists
EXISTING_NODES=$(api_call GET "/nodes") || true
NODE_ID=$(echo "$EXISTING_NODES" | jq -r ".data[] | select(.attributes.name==\"${NODE_NAME}\") | .attributes.id" 2>/dev/null)

if [ -n "$NODE_ID" ] && [ "$NODE_ID" != "null" ]; then
    log "Node already exists: ID $NODE_ID"
else
    NODE_RESPONSE=$(api_call POST "/nodes" "{
        \"name\": \"${NODE_NAME}\",
        \"location_id\": ${LOCATION_ID},
        \"fqdn\": \"${NODE_FQDN}\",
        \"scheme\": \"${SCHEME}\",
        \"memory\": ${NODE_MEMORY_MB},
        \"memory_overallocate\": 0,
        \"disk\": ${NODE_DISK_MB},
        \"disk_overallocate\": 0,
        \"upload_size\": 100,
        \"daemon_sftp\": ${SFTP_PORT},
        \"daemon_listen\": ${WINGS_PORT},
        \"behind_proxy\": false,
        \"maintenance_mode\": false
    }") || {
        err "Failed to create node. Check API response above."
    }
    if ! NODE_ID=$(echo "$NODE_RESPONSE" | jq -r '.attributes.id' 2>/dev/null) || [ -z "$NODE_ID" ] || [ "$NODE_ID" = "null" ]; then
        err "Failed to parse node ID from response: $NODE_RESPONSE"
    fi
    log "Node created: ID $NODE_ID"
fi

###############################################################################
# 9. WRITE WINGS CONFIG.YML
###############################################################################
step "Writing Wings config.yml"

CONFIG_RESPONSE=$(api_call GET "/nodes/${NODE_ID}/configuration") || {
    err "Failed to fetch Wings config. Check API response above."
}
echo "$CONFIG_RESPONSE" | jq '.' > /dev/null 2>&1 || err "Invalid config JSON: $CONFIG_RESPONSE"

# The panel writes /etc/letsencrypt/live/<fqdn>/ into the config regardless of
# where the certificate really is, so point Wings at the one nginx is serving.
WINGS_SSL_CERT="$SSL_CERT" WINGS_SSL_KEY="$SSL_KEY" \
python3 - "$CONFIG_RESPONSE" <<'PYEOF'
import json, os, sys

config = json.loads(sys.argv[1])

ssl = config.setdefault("api", {}).setdefault("ssl", {})
ssl["enabled"] = True
ssl["cert"] = os.environ["WINGS_SSL_CERT"]
ssl["key"] = os.environ["WINGS_SSL_KEY"]

def to_yaml(obj, indent=0):
    lines = []
    pad = "  " * indent
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, (dict, list)) and v:
                lines.append(f"{pad}{k}:")
                lines.append(to_yaml(v, indent + 1))
            elif isinstance(v, bool):
                lines.append(f"{pad}{k}: {'true' if v else 'false'}")
            elif isinstance(v, str):
                needs_quote = any(c in v for c in [':', '#', '{', '}', '[', ']', ',', '&', '*', '?', '|', '<', '>', '=', '!', '%', '@', '\\', '\n']) or v == ''
                if needs_quote:
                    escaped = v.replace('\\', '\\\\').replace('"', '\\"')
                    lines.append(f'{pad}{k}: "{escaped}"')
                else:
                    lines.append(f"{pad}{k}: {v}")
            elif v is None:
                lines.append(f"{pad}{k}: null")
            else:
                lines.append(f"{pad}{k}: {v}")
    elif isinstance(obj, list):
        if not obj:
            return f"{pad}[]"
        for item in obj:
            if isinstance(item, dict):
                lines.append(f"{pad}-")
                lines.append(to_yaml(item, indent + 1))
            else:
                lines.append(f"{pad}- {item}")
    return "\n".join(lines)

with open("/etc/pterodactyl/config.yml", "w") as f:
    f.write(to_yaml(config) + "\n")
print("OK")
PYEOF

log "Wings config.yml written ($(wc -c < /etc/pterodactyl/config.yml) bytes)"

###############################################################################
# 10. CREATE ALLOCATIONS
###############################################################################
step "Creating allocations"

create_alloc_range() {
    local label="$1" start="$2" end="$3"
    local A='{"ip":"0.0.0.0","ports":['
    for p in $(seq "$start" "$end"); do A+="\"$p\","; done
    A="${A%,}]}"
    local RESP
    RESP=$("${CURL[@]}" -w "\n%{http_code}" -X POST \
        "${API_URL}/nodes/${NODE_ID}/allocations" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$A")
    local CODE
    CODE=$(echo "$RESP" | tail -1)
    if [[ "$CODE" =~ ^2[0-9][0-9]$ ]]; then
        log "  $label ($start-$end) created"
    elif [ "$CODE" = "422" ]; then
        log "  $label ($start-$end) already exist"
    else
        warn "  $label ($start-$end) returned HTTP $CODE"
    fi
}

# Minecraft / Game servers
create_alloc_range "Game ports" 25565 25575
# Web apps (Node.js, Python, Bun, Golang, Rust, Uptime Kuma, etc.)
create_alloc_range "Web/App ports" 3000 3015
create_alloc_range "Web/App ports" 5000 5010
create_alloc_range "Web/App ports" 8000 8010
create_alloc_range "Web/App ports" 8080 8090
# Bot / misc ports
create_alloc_range "Bot/misc ports" 6000 6010
log "All allocations created"

###############################################################################
# 10b. IMPORT COMMUNITY EGGS (Node.js, Python, etc.)
# This entire section is optional — errors here won't stop the installer
###############################################################################
step "Importing community eggs (Node.js, Python, etc.)"

(
  set +e   # Disable exit-on-error for this subshell

  cd /var/www/pterodactyl

cat > app/Console/Commands/ImportCommunityEggs.php <<'PHPCMD'
<?php
namespace Pterodactyl\Console\Commands;

use Illuminate\Console\Command;
use Pterodactyl\Models\Egg;
use Pterodactyl\Models\Nest;
use Pterodactyl\Models\EggVariable;
use Ramsey\Uuid\Uuid;
use Illuminate\Support\Arr;

class ImportCommunityEggs extends Command
{
    protected $signature = 'p:eggs:import-community';
    protected $description = 'Download and import popular community eggs';

    // Community egg URLs from parkervcp/eggs (the standard community repo)
    private array $eggSources = [
        // ── Software / Generic ──
        'Generic' => [
            'Node.js Generic'   => 'https://raw.githubusercontent.com/parkervcp/eggs/master/generic/nodejs/egg-node-js-generic.json',
            'Python Generic'    => 'https://raw.githubusercontent.com/parkervcp/eggs/master/generic/python/egg-python-generic.json',
            'Java Generic'      => 'https://raw.githubusercontent.com/parkervcp/eggs/master/generic/java/egg-java.json',
            'Golang Generic'    => 'https://raw.githubusercontent.com/parkervcp/eggs/master/generic/golang/egg-golang-generic.json',
            'Rust Generic'      => 'https://raw.githubusercontent.com/parkervcp/eggs/master/generic/rust/egg-rust-generic.json',
            'Bun Generic'       => 'https://raw.githubusercontent.com/parkervcp/eggs/master/generic/bun/egg-bun.json',
        ],
        // ── Bots ──
        'Bots' => [
            'Red Bot'          => 'https://raw.githubusercontent.com/parkervcp/eggs/master/bots/discord/redbot/egg-red.json',
            'SinusBot'         => 'https://raw.githubusercontent.com/parkervcp/eggs/master/bots/discord/sinusbot/egg-sinusbot.json',
            'Bastion'          => 'https://raw.githubusercontent.com/parkervcp/eggs/master/bots/discord/bastion/egg-bastion.json',
            'JMusicBot'        => 'https://raw.githubusercontent.com/parkervcp/eggs/master/bots/discord/jmusicbot/egg-j-music-bot.json',
        ],
        // ── Game Servers (extras) ──
        'Game Servers' => [
            'FiveM'            => 'https://raw.githubusercontent.com/parkervcp/eggs/master/game_eggs/gta/fivem/egg-five-m.json',
            'Valheim'          => 'https://raw.githubusercontent.com/parkervcp/eggs/master/game_eggs/steamcmd_servers/valheim/valheim_vanilla/egg-valheim.json',
            'Palworld'         => 'https://raw.githubusercontent.com/parkervcp/eggs/master/game_eggs/steamcmd_servers/palworld/egg-palworld.json',
            'Terraria'         => 'https://raw.githubusercontent.com/parkervcp/eggs/master/game_eggs/terraria/vanilla/egg-terraria-vanilla.json',
        ],
        // ── Databases ──
        'Databases' => [
            'MongoDB'          => 'https://raw.githubusercontent.com/parkervcp/eggs/master/database/nosql/mongodb/egg-mongo-d-b7.json',
            'Redis'            => 'https://raw.githubusercontent.com/parkervcp/eggs/master/database/redis/redis-7/egg-redis-7.json',
            'PostgreSQL'       => 'https://raw.githubusercontent.com/parkervcp/eggs/master/database/sql/postgres/egg-postgres16.json',
        ],
        // ── Monitoring / Tools ──
        'Monitoring' => [
            'Uptime Kuma'      => 'https://raw.githubusercontent.com/parkervcp/eggs/master/software/uptime-kuma/egg-uptime-kuma.json',
        ],
    ];

    public function handle(): int
    {
        $imported = 0;
        $failed = 0;

        foreach ($this->eggSources as $nestName => $eggs) {
            // Find or create nest
            $nest = Nest::where('name', $nestName)->first();
            if (!$nest) {
                $nest = Nest::forceCreate([
                    'uuid'        => Uuid::uuid4()->toString(),
                    'author'      => 'auto-installer@pterodactyl.io',
                    'name'        => $nestName,
                    'description' => "Auto-imported: {$nestName}",
                ]);
                fwrite(STDERR, "NEST_CREATED:{$nestName}:id={$nest->id}\n");
            } else {
                fwrite(STDERR, "NEST_EXISTS:{$nestName}:id={$nest->id}\n");
            }

            foreach ($eggs as $eggLabel => $url) {
                // Skip if egg already exists in this nest (check both our label and JSON name)
                $existing = Egg::where('nest_id', $nest->id)
                    ->where(function($q) use ($eggLabel) {
                        $q->where('name', $eggLabel);
                    })->first();
                if ($existing) {
                    fwrite(STDERR, "EGG_SKIP:{$eggLabel} (already exists)\n");
                    continue;
                }

                // Download egg JSON
                $json = @file_get_contents($url);
                if (!$json) {
                    fwrite(STDERR, "EGG_FAIL:{$eggLabel} (download failed: {$url})\n");
                    $failed++;
                    continue;
                }

                $parsed = json_decode($json, true);
                if (!$parsed || !isset($parsed['meta']['version'])) {
                    fwrite(STDERR, "EGG_FAIL:{$eggLabel} (invalid JSON)\n");
                    $failed++;
                    continue;
                }

                // Also check by the JSON's actual name
                $jsonName = $parsed['name'] ?? $eggLabel;
                if ($jsonName !== $eggLabel) {
                    $existByJsonName = Egg::where('nest_id', $nest->id)->where('name', $jsonName)->first();
                    if ($existByJsonName) {
                        fwrite(STDERR, "EGG_SKIP:{$eggLabel} (already exists as '{$jsonName}')\n");
                        continue;
                    }
                }

                // Handle v1 → v2 conversion
                if (($parsed['meta']['version'] ?? '') === 'PTDL_v1') {
                    if (!isset($parsed['images'])) {
                        $images = [Arr::get($parsed, 'image') ?? 'nil'];
                    } else {
                        $images = $parsed['images'];
                    }
                    unset($parsed['images'], $parsed['image']);
                    $parsed['docker_images'] = [];
                    foreach ($images as $image) {
                        $parsed['docker_images'][$image] = $image;
                    }
                    if (isset($parsed['variables'])) {
                        $parsed['variables'] = array_map(fn($v) => array_merge($v, ['field_type' => 'text']), $parsed['variables']);
                    }
                }

                try {
                    $egg = (new Egg())->forceFill([
                        'uuid'              => Uuid::uuid4()->toString(),
                        'nest_id'           => $nest->id,
                        'author'            => Arr::get($parsed, 'author', 'unknown@unknown.com'),
                        'copy_script_from'  => null,
                        'name'              => Arr::get($parsed, 'name', $eggLabel),
                        'description'       => Arr::get($parsed, 'description'),
                        'features'          => Arr::get($parsed, 'features'),
                        'docker_images'     => Arr::get($parsed, 'docker_images'),
                        'file_denylist'     => collect(Arr::get($parsed, 'file_denylist', []))->filter(fn($v) => !empty($v)),
                        'update_url'        => Arr::get($parsed, 'meta.update_url'),
                        'config_files'      => Arr::get($parsed, 'config.files'),
                        'config_startup'    => Arr::get($parsed, 'config.startup'),
                        'config_logs'       => Arr::get($parsed, 'config.logs'),
                        'config_stop'       => Arr::get($parsed, 'config.stop'),
                        'startup'           => Arr::get($parsed, 'startup'),
                        'script_install'    => Arr::get($parsed, 'scripts.installation.script'),
                        'script_entry'      => Arr::get($parsed, 'scripts.installation.entrypoint', 'bash'),
                        'script_container'  => Arr::get($parsed, 'scripts.installation.container', 'ghcr.io/parkervcp/installers:debian'),
                    ]);
                    $egg->save();

                    foreach ($parsed['variables'] ?? [] as $variable) {
                        EggVariable::query()->forceCreate(array_merge($variable, ['egg_id' => $egg->id]));
                    }

                    fwrite(STDERR, "EGG_OK:{$eggLabel}\n");
                    $imported++;
                } catch (\Throwable $e) {
                    fwrite(STDERR, "EGG_FAIL:{$eggLabel} ({$e->getMessage()})\n");
                    $failed++;
                }
            }
        }

        fwrite(STDERR, "SUMMARY:imported={$imported},failed={$failed}\n");
        echo ($failed === 0) ? "OK" : "PARTIAL";
        return ($failed === 0) ? 0 : 1;
    }
}
PHPCMD

php artisan clear-compiled 2>/dev/null || true

EGG_STDERR=$(php artisan p:eggs:import-community --no-interaction 2>&1 1>/tmp/egg_import_stdout.txt) || true
EGG_RESULT=$(cat /tmp/egg_import_stdout.txt | tr -d '[:space:]')

# Show results
echo "$EGG_STDERR" | grep "NEST_CREATED:" | while read line; do
    log "  Created nest: $(echo "$line" | sed 's/NEST_CREATED://' | cut -d: -f1)"
done || true
echo "$EGG_STDERR" | grep "EGG_OK:" | while read line; do
    log "  Imported: $(echo "$line" | sed 's/EGG_OK://')"
done || true
echo "$EGG_STDERR" | grep "EGG_SKIP:" | while read line; do
    warn "  Skipped: $(echo "$line" | sed 's/EGG_SKIP://')"
done || true
echo "$EGG_STDERR" | grep "EGG_FAIL:" | while read line; do
    warn "  Failed: $(echo "$line" | sed 's/EGG_FAIL://')"
done || true

SUMMARY_LINE=$(echo "$EGG_STDERR" | grep "SUMMARY:" | tail -1 || true)
if [ -n "$SUMMARY_LINE" ]; then
    log "  $SUMMARY_LINE"
fi

rm -f app/Console/Commands/ImportCommunityEggs.php
php artisan clear-compiled 2>/dev/null || true

if [ "$EGG_RESULT" = "OK" ]; then
    log "All community eggs imported successfully"
elif [ "$EGG_RESULT" = "PARTIAL" ]; then
    warn "Some eggs failed to import (see above). Non-critical — continuing."
else
    warn "Egg import had issues. Non-critical — you can import manually from the admin panel."
fi

) || warn "Egg import section encountered an error — skipping. You can import eggs manually from ${APP_URL}/admin/nests"

###############################################################################
# 11. START WINGS
###############################################################################
step "Starting Wings"

systemctl enable --now wings
sleep 4

if systemctl is-active --quiet wings; then
    log "Wings is RUNNING"
else
    warn "Wings starting up. Check: journalctl -u wings -f"
fi

###############################################################################
# 12. FIREWALL
###############################################################################
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    step "Configuring firewall"
    ufw allow 80/tcp    >/dev/null 2>&1
    ufw allow 443/tcp   >/dev/null 2>&1
    ufw allow ${WINGS_PORT}/tcp  >/dev/null 2>&1
    ufw allow ${SFTP_PORT}/tcp   >/dev/null 2>&1
    ufw allow 25565:25575/tcp    >/dev/null 2>&1
    ufw allow 3000:3015/tcp      >/dev/null 2>&1
    ufw allow 5000:5010/tcp      >/dev/null 2>&1
    ufw allow 8000:8010/tcp      >/dev/null 2>&1
    ufw allow 8080:8090/tcp      >/dev/null 2>&1
    ufw allow 6000:6010/tcp      >/dev/null 2>&1
    log "Firewall rules added"
fi

###############################################################################
# 13. GENERATE README
###############################################################################
step "Saving credentials to README"

INSTALL_DATE=$(date '+%Y-%m-%d %H:%M:%S %Z')
README_PATH="/root/pterodactyl-credentials.md"

if [ "$SSL_IS_TRUSTED" = "yes" ]; then
    SSL_IS_TRUSTED_LABEL="Let's Encrypt (trusted)"
else
    SSL_IS_TRUSTED_LABEL="self-signed -- your browser will warn once, and the console needs https://${PUBLIC_IP}:${WINGS_PORT} accepted too"
fi

cat > "$README_PATH" <<READMEOF
# Pterodactyl Panel — Installation Credentials

> **Installed:** ${INSTALL_DATE}
> **Server IP:** ${PUBLIC_IP}

---

## Panel Access

| Field           | Value                       |
|-----------------|-----------------------------|
| **URL**         | ${APP_URL}                  |
| **Certificate** | ${SSL_IS_TRUSTED_LABEL}     |
| **Admin User**  | ${ADMIN_USER}               |
| **Admin Email** | ${ADMIN_EMAIL}              |
| **Password**    | ${ADMIN_PASSWORD}           |

---

## Node

| Field           | Value                       |
|-----------------|-----------------------------|
| **Name**        | ${NODE_NAME}                |
| **Node ID**     | ${NODE_ID}                  |
| **FQDN**        | ${PUBLIC_IP}                |
| **Wings Port**  | ${WINGS_PORT}               |
| **SFTP Port**   | ${SFTP_PORT}                |
| **Wings Config**| /etc/pterodactyl/config.yml |

---

## Port Allocations

| Range         | Purpose                                    |
|---------------|--------------------------------------------|
| 25565-25575   | Minecraft / Game servers                   |
| 3000-3015     | Node.js / Web apps                         |
| 5000-5010     | Python (Flask/FastAPI) / Web apps           |
| 8000-8010     | Django / General web servers               |
| 8080-8090     | Alt HTTP / Reverse proxies                 |
| 6000-6010     | Bots / Misc services                       |

---

## Database

| Field               | Value                   |
|---------------------|-------------------------|
| **DB Root Password**| ${DB_ROOT_PASS}         |
| **Panel DB Name**   | ${DB_PANEL_NAME}        |
| **Panel DB User**   | ${DB_PANEL_USER}        |
| **Panel DB Pass**   | ${DB_PANEL_PASS}        |

---

## API Key

\`\`\`
${PANEL_API_KEY}
\`\`\`

---

## Useful Commands

\`\`\`bash
# Check service status
systemctl status wings
systemctl status pteroq
systemctl status nginx
systemctl status php8.3-fpm
systemctl status mariadb
systemctl status redis-server

# View logs
journalctl -u wings -f
journalctl -u pteroq -f
tail -f /var/log/nginx/pterodactyl.app-error.log

# View install log
cat ${LOG_FILE}
# or with less for scrolling:
less ${LOG_FILE}

# Restart all services
systemctl restart wings pteroq nginx php8.3-fpm mariadb redis-server
\`\`\`

---

> **⚠ KEEP THIS FILE SECURE** — it contains passwords and API keys.
> Consider moving it off-server after saving the credentials.
READMEOF

chmod 600 "$README_PATH"
log "Credentials saved to $README_PATH"

###############################################################################
# CLEANUP INSTALL STATUS PAGE
###############################################################################
# Signal the browser that installation is complete
for d in /var/www/html /var/www/pterodactyl/public; do
    [ -d "$d" ] && echo "COMPLETE" > "$d/install-status.txt" 2>/dev/null
done
sleep 5

# Stop background log sync
rm -f /tmp/.ptero_install_running
kill "$LOG_SYNC_PID" 2>/dev/null; wait "$LOG_SYNC_PID" 2>/dev/null || true

# Remove temporary status page files
for d in /var/www/html /var/www/pterodactyl/public; do
    rm -f "$d/index.html" "$d/install-log.txt" "$d/install-status.txt" 2>/dev/null
done
log "Install status page removed"

###############################################################################
# DONE
###############################################################################
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  PTERODACTYL INSTALLATION COMPLETE${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Panel URL:        ${CYAN}${APP_URL}${NC}"
echo -e "  Certificate:      ${CYAN}${SSL_IS_TRUSTED_LABEL}${NC}"
echo -e "  Admin User:       ${CYAN}${ADMIN_USER}${NC}"
echo -e "  Admin Email:      ${CYAN}${ADMIN_EMAIL}${NC}"
echo -e "  Admin Password:   ${CYAN}the one you chose when ordering${NC}"
echo ""
echo -e "  Node Name:        ${CYAN}${NODE_NAME}${NC}"
echo -e "  Node ID:          ${CYAN}${NODE_ID}${NC}"
echo -e "  Wings Port:       ${CYAN}${WINGS_PORT}${NC}"
echo -e "  SFTP Port:        ${CYAN}${SFTP_PORT}${NC}"
echo ""
echo -e "  Allocations:"
echo -e "    Game servers:   ${CYAN}25565-25575${NC}"
echo -e "    Web/App (Node): ${CYAN}3000-3015${NC}"
echo -e "    Web/App (Py):   ${CYAN}5000-5010${NC}"
echo -e "    Web/App (Alt):  ${CYAN}8000-8010, 8080-8090${NC}"
echo -e "    Bot/misc:       ${CYAN}6000-6010${NC}"
echo ""
echo -e "  Wings Config:     ${CYAN}/etc/pterodactyl/config.yml${NC}"
echo ""
echo -e "  ${YELLOW}DB Root Password:   ${DB_ROOT_PASS}${NC}"
echo -e "  ${YELLOW}DB Panel Password:  ${DB_PANEL_PASS}${NC}"
echo -e "  ${YELLOW}API Key:            ${PANEL_API_KEY}${NC}"
echo ""
echo -e "  ${GREEN}Credentials saved to: ${README_PATH}${NC}"
echo -e "  ${GREEN}Full install log:     ${LOG_FILE}${NC}"
echo ""
echo -e "  ${RED}⚠  SAVE THESE CREDENTIALS — they won't be shown again!${NC}"
echo ""
echo -e "  Services:"
echo -e "    systemctl status wings"
echo -e "    systemctl status pteroq"
echo -e "    systemctl status nginx"
echo -e "    systemctl status php8.3-fpm"
echo -e "    systemctl status mariadb"
echo -e "    systemctl status redis-server"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Final log entry
_log_to_file "==============================================================================="
_log_to_file "  Installation completed at $(date '+%Y-%m-%d %H:%M:%S %Z')"
_log_to_file "==============================================================================="
