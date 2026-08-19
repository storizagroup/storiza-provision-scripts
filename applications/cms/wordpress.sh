#!/usr/bin/env bash
#
# WordPress on nginx + PHP-FPM + MariaDB -- Storiza provision script.
#
# Run once by cloud-init while a Storiza VPS first boots. The customer's
# answers arrive in a file, never as arguments:
#
#     /etc/storiza/provision.json   { "vps": {...}, "inputs": {...} }
#
# Inputs consumed:
#     inputs.admin_email     -- the WordPress administrator, required
#     inputs.admin_password  -- its password, required
#     inputs.site_domain     -- optional; the site answers on the IP without it
#     inputs.site_title      -- optional, defaults to "My WordPress Site"
#
# The install is finished here, not left on the five-minute setup screen: an
# unclaimed WordPress on a public IP is claimed by whoever finds it first.
#
# HTTPS: Let's Encrypt when a domain was answered and its DNS already points
# here, self-signed otherwise. Port 80 only redirects.
#
# Upstream: https://wordpress.org  (GPL-2.0-or-later, the WordPress project)
set -euo pipefail

LOG=/var/log/storiza-provision.log
exec > >(tee -a "$LOG") 2>&1
echo "[storiza] WordPress provisioning started $(date -Is)"

DATA=${PROVISION_DATA:-/etc/storiza/provision.json}
[ -r "$DATA" ] || { echo "[storiza] $DATA missing -- nothing to install"; exit 1; }

command -v jq >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y jq >/dev/null; }
answer() { jq -r "$1 // empty" "$DATA"; }

ADMIN_EMAIL=$(answer '.inputs.admin_email')
ADMIN_PASSWORD=$(answer '.inputs.admin_password')
SITE_DOMAIN=$(answer '.inputs.site_domain')
SITE_TITLE=$(answer '.inputs.site_title')
IP_ADDRESS=$(answer '.vps.ip.address')
SITE_TITLE=${SITE_TITLE:-My WordPress Site}

[ -n "$ADMIN_EMAIL" ]    || { echo "[storiza] inputs.admin_email is required"; exit 1; }
[ -n "$ADMIN_PASSWORD" ] || { echo "[storiza] inputs.admin_password is required"; exit 1; }

SITE_HOST=${SITE_DOMAIN:-$IP_ADDRESS}
WEBROOT=/var/www/wordpress
DB_NAME=wordpress
DB_USER=wordpress
DB_PASSWORD=$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 32)

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y nginx mariadb-server openssl certbot python3-certbot-nginx curl \
	php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-zip php-intl php-imagick >/dev/null

PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
PHP_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"

systemctl enable --now mariadb

# The database password is generated here and never leaves the server; it goes
# into wp-config.php and the root-only summary, nowhere else.
mysql --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "[storiza] installing WP-CLI"
curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
chmod +x /usr/local/bin/wp

echo "[storiza] downloading WordPress"
mkdir -p "$WEBROOT"
chown -R www-data:www-data "$WEBROOT"
wp --allow-root --path="$WEBROOT" core download

wp --allow-root --path="$WEBROOT" config create \
	--dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost=localhost

# ── nginx, TLS first ────────────────────────────────────────────────────────
mkdir -p /etc/storiza/ssl
SAN="IP:${IP_ADDRESS}"
[ -n "$SITE_DOMAIN" ] && SAN="DNS:${SITE_DOMAIN},${SAN}"
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -sha256 \
	-keyout /etc/storiza/ssl/self.key -out /etc/storiza/ssl/self.crt \
	-subj "/CN=${SITE_HOST}" -addext "subjectAltName=${SAN}" 2>/dev/null
chmod 600 /etc/storiza/ssl/self.key

cat > /etc/nginx/sites-available/wordpress.conf <<NGINX
server {
    listen 80;
    server_name ${SITE_DOMAIN:-_};

    location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    server_name ${SITE_DOMAIN:-_};

    root ${WEBROOT};
    index index.php index.html;

    ssl_certificate     /etc/storiza/ssl/self.crt;
    ssl_certificate_key /etc/storiza/ssl/self.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 128m;

    location / { try_files \$uri \$uri/ /index.php?\$args; }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_param HTTPS on;
        fastcgi_read_timeout 300;
    }

    location ~ /\.(ht|git) { deny all; }
    location = /xmlrpc.php { deny all; }
}
NGINX
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/wordpress.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx "php${PHP_VERSION}-fpm"

CERT_NOTE="self-signed -- the browser warns once"
if [ -n "$SITE_DOMAIN" ]; then
	echo "[storiza] requesting a Let's Encrypt certificate for ${SITE_DOMAIN}"
	if certbot --nginx -d "$SITE_DOMAIN" --non-interactive --agree-tos \
		-m "$ADMIN_EMAIL" --redirect --keep-until-expiring; then
		CERT_NOTE="Let's Encrypt (trusted)"
	else
		echo "[storiza] Let's Encrypt could not verify ${SITE_DOMAIN} -- keeping the self-signed certificate"
		echo "[storiza] once its A record resolves here, run: certbot --nginx -d ${SITE_DOMAIN}"
	fi
	systemctl reload nginx || true
fi

# ── Finish the install so nobody else can ───────────────────────────────────
wp --allow-root --path="$WEBROOT" core install \
	--url="https://${SITE_HOST}" \
	--title="$SITE_TITLE" \
	--admin_user=admin \
	--admin_password="$ADMIN_PASSWORD" \
	--admin_email="$ADMIN_EMAIL" \
	--skip-email

wp --allow-root --path="$WEBROOT" rewrite structure '/%postname%/' --hard || true
chown -R www-data:www-data "$WEBROOT"
find "$WEBROOT" -type d -exec chmod 755 {} \;
find "$WEBROOT" -type f -exec chmod 644 {} \;

cat > /root/wordpress-credentials.md <<CREDS
# WordPress

| | |
|---|---|
| Site | https://${SITE_HOST} |
| Admin | https://${SITE_HOST}/wp-admin |
| Username | admin |
| Email | ${ADMIN_EMAIL} |
| Password | the one you chose when ordering |
| Certificate | ${CERT_NOTE} |

Database: ${DB_NAME}, user ${DB_USER}, password ${DB_PASSWORD}
(the same values are in ${WEBROOT}/wp-config.php)

> Keep this file secure -- it contains the database password.
CREDS
chmod 600 /root/wordpress-credentials.md

echo "[storiza] WordPress ready at https://${SITE_HOST}"
echo "[storiza] WordPress provisioning finished $(date -Is)"
