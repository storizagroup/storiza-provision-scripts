#!/usr/bin/env bash
#
# WordPress on nginx + PHP-FPM + MariaDB -- Storiza provision script.
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
# Ports: 80 and 443, nothing else. MariaDB listens on localhost only and has
# no business being reachable.
#
# Upstream: https://wordpress.org  (GPL-2.0-or-later, the WordPress project)
set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/storizagroup/storiza-provision-scripts/main/lib/provision.sh \
	-o /tmp/storiza-lib.sh && . /tmp/storiza-lib.sh

storiza_start "WordPress" \
	"Reading your answers" \
	"Installing nginx, PHP and MariaDB" \
	"Creating the database" \
	"Downloading WordPress" \
	"Publishing the site over HTTPS" \
	"Finishing the WordPress install" \
	"Closing the ports nothing should reach"

WEBROOT=/var/www/wordpress
DB_NAME=wordpress
DB_USER=wordpress

step
ADMIN_EMAIL=$(need '.inputs.admin_email')
ADMIN_PASSWORD=$(need '.inputs.admin_password')
SITE_DOMAIN=$(answer '.inputs.site_domain')
SITE_TITLE=$(answer '.inputs.site_title')
IP_ADDRESS=$(answer '.vps.ip.address')
SITE_TITLE=${SITE_TITLE:-My WordPress Site}
SITE_HOST=${SITE_DOMAIN:-$IP_ADDRESS}

step
pkg nginx mariadb-server openssl curl \
	php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-zip php-intl php-imagick
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
PHP_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
systemctl enable --now mariadb

step
# The database password is generated here and never leaves the server; it goes
# into wp-config.php and the root-only summary, nowhere else.
DB_PASSWORD=$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 32)
mysql --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

step
curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
chmod +x /usr/local/bin/wp
mkdir -p "$WEBROOT"
chown -R www-data:www-data "$WEBROOT"
wp --allow-root --path="$WEBROOT" core download
wp --allow-root --path="$WEBROOT" config create \
	--dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost=localhost

step
# Not serve_https: this is a root site served by PHP-FPM, not a proxy to a
# port. The certificate and the Let's Encrypt attempt are shared all the same.
self_signed "$SITE_HOST" "$IP_ADDRESS"

cat > /etc/nginx/sites-available/storiza.conf <<NGINX
server {
    listen 80;
    server_name ${SITE_DOMAIN:-_};

    location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    # No http2 here: the directive spelling changed in nginx 1.25 and Ubuntu
    # 22.04 still ships 1.18, where it fails the config test.
    listen 443 ssl;
    server_name ${SITE_DOMAIN:-_};

    root ${WEBROOT};
    index index.php index.html;

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
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
mkdir -p /var/www/html
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/storiza.conf /etc/nginx/sites-enabled/storiza.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx "php${PHP_VERSION}-fpm"

certbot_try "$SITE_DOMAIN" "$ADMIN_EMAIL"

step
wp --allow-root --path="$WEBROOT" core install \
	--url="https://${SITE_HOST}" \
	--title="$SITE_TITLE" \
	--admin_user=admin \
	--admin_password="$ADMIN_PASSWORD" \
	--admin_email="$ADMIN_EMAIL" \
	--skip-email \
	|| fail "WordPress was downloaded, but the install could not be completed."

wp --allow-root --path="$WEBROOT" rewrite structure '/%postname%/' --hard || true
chown -R www-data:www-data "$WEBROOT"
find "$WEBROOT" -type d -exec chmod 755 {} \;
find "$WEBROOT" -type f -exec chmod 644 {} \;

step
allow_ports 80/tcp 443/tcp

credentials <<CREDS
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

Only 80, 443 and SSH accept connections. Open anything else with
\`ufw allow <port>\`.
CREDS

echo "[storiza] WordPress ready at https://${SITE_HOST}"
