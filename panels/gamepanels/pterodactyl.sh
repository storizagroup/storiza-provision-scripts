#!/usr/bin/env bash
#
# Pterodactyl Panel + Wings -- Storiza provision script.
#
# Inputs consumed:
#     inputs.admin_email     -- the panel administrator, required
#     inputs.admin_password  -- its password, required
#     inputs.panel_domain    -- optional; the panel answers on the IP without it
#
# The server is handed over ready: panel installed, administrator created,
# Wings running, a node registered against this machine, port allocations
# made, and the common community eggs imported. Nothing is left on a setup
# wizard, because an unclaimed game panel on a public IP is claimed by
# whoever finds it first.
#
# HTTPS everywhere, and not as decoration: a page served over HTTPS may not
# open a plaintext websocket, so an http node means a dead server console.
# Let's Encrypt when a domain was answered and its DNS already points here,
# self-signed otherwise -- and the node is addressed by whichever name the
# certificate is actually valid for.
#
# Ports: no allow list. This is a game panel; the customer's servers listen on
# whatever ports their games use, Wings needs 8080 and 2022, and an allow list
# would fight all of it. What is closed instead are the two services that have
# no business being reachable from the internet -- MariaDB, which holds a user
# with full privileges so Wings can create per-server databases, and Redis.
#
# Upstream: https://pterodactyl.io  (MIT, Dane Everitt and contributors)
set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/storizagroup/storiza-provision-scripts/main/lib/provision.sh \
	-o /tmp/storiza-lib.sh && . /tmp/storiza-lib.sh

storiza_start "Pterodactyl" \
	"Reading your answers" \
	"Installing system dependencies" \
	"Configuring the database" \
	"Installing the panel" \
	"Publishing the panel over HTTPS" \
	"Installing Wings" \
	"Registering this server as a node" \
	"Creating port allocations" \
	"Importing community eggs" \
	"Starting Wings" \
	"Closing the ports nothing should reach"

PHP_VER=8.3
PANEL_DIR=/var/www/pterodactyl
NODE_NAME="node-01"
LOCATION_SHORT="dc-1"
LOCATION_LONG="Datacenter 1"
WINGS_PORT=8080
SFTP_PORT=2022

step
ADMIN_EMAIL=$(need '.inputs.admin_email')
ADMIN_PASSWORD=$(need '.inputs.admin_password')
PANEL_DOMAIN=$(answer '.inputs.panel_domain')
PUBLIC_IP=$(answer '.vps.ip.address')
[ -n "$PUBLIC_IP" ] || PUBLIC_IP=$(curl -4 -s --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')

PANEL_FQDN="${PANEL_DOMAIN:-$PUBLIC_IP}"
APP_URL="https://${PANEL_FQDN}"

# Fixed rather than asked: one administrator is created and the customer
# renames it from inside the panel.
DB_ROOT_PASS="R00t_$(openssl rand -hex 8)"
DB_PANEL_PASS="Pt3r0_$(openssl rand -hex 8)"
DB_PANEL_USER=pterodactyl
DB_PANEL_NAME=panel

step
. /etc/os-release
if [ "${ID:-}" = "ubuntu" ]; then
	pkg software-properties-common
	add-apt-repository -y ppa:ondrej/php > /dev/null
elif [ "${ID:-}" = "debian" ]; then
	pkg lsb-release ca-certificates
	curl -fsSLo /tmp/sury.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
	dpkg -i /tmp/sury.deb
	echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-archive.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
		> /etc/apt/sources.list.d/sury-php.list
	rm -f /tmp/sury.deb
else
	fail "Pterodactyl installs on Ubuntu or Debian, and this server runs ${PRETTY_NAME:-an unknown system}."
fi
pkg_refresh

pkg curl tar unzip git redis-server mariadb-server nginx openssl python3-yaml \
	"php${PHP_VER}" "php${PHP_VER}-cli" "php${PHP_VER}-gd" "php${PHP_VER}-mysql" \
	"php${PHP_VER}-pdo" "php${PHP_VER}-mbstring" "php${PHP_VER}-tokenizer" \
	"php${PHP_VER}-bcmath" "php${PHP_VER}-xml" "php${PHP_VER}-fpm" \
	"php${PHP_VER}-curl" "php${PHP_VER}-zip" "php${PHP_VER}-intl" \
	"php${PHP_VER}-readline" "php${PHP_VER}-common" "php${PHP_VER}-opcache"

export HOME=/root COMPOSER_HOME=/root/.composer
curl -fsSL https://getcomposer.org/installer \
	| php -- --install-dir=/usr/local/bin --filename=composer > /dev/null

step
systemctl enable --now mariadb
mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL

mysql -u root -p"${DB_ROOT_PASS}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_PANEL_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_PANEL_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PANEL_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_PANEL_NAME}\`.* TO '${DB_PANEL_USER}'@'127.0.0.1' WITH GRANT OPTION;

-- Wings creates a database per game server, so it needs an account that can
-- create them. This is why 3306 is closed to the internet at the end.
CREATE USER IF NOT EXISTS '${DB_PANEL_USER}'@'%' IDENTIFIED BY '${DB_PANEL_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${DB_PANEL_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

step
mkdir -p "$PANEL_DIR"
cd "$PANEL_DIR"
curl -fsSLo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
rm -f panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/
cp .env.example .env

composer install --no-dev --optimize-autoloader --no-interaction > /dev/null
php artisan key:generate --force --no-interaction > /dev/null

php artisan p:environment:setup \
	--author="$ADMIN_EMAIL" --url="$APP_URL" --timezone=UTC \
	--cache=redis --session=redis --queue=redis \
	--redis-host=127.0.0.1 --redis-pass="" --redis-port=6379 \
	--settings-ui=true --telemetry=false --no-interaction

php artisan p:environment:database \
	--host=127.0.0.1 --port=3306 --database="$DB_PANEL_NAME" \
	--username="$DB_PANEL_USER" --password="$DB_PANEL_PASS" --no-interaction

php artisan migrate --seed --force --no-interaction \
	|| fail "The panel's database migration did not complete."

php artisan p:user:make \
	--email="$ADMIN_EMAIL" --username=admin \
	--name-first=Server --name-last=Administrator \
	--password="$ADMIN_PASSWORD" --admin=1 --no-interaction \
	|| fail "The panel installed, but the administrator account could not be created."

chown -R www-data:www-data "$PANEL_DIR"/*
(crontab -l -u www-data 2> /dev/null || true; echo "* * * * * php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1") \
	| crontab -u www-data -

cat > /etc/systemd/system/pteroq.service <<UNIT
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
RestartSec=5s
ExecStart=/usr/bin/php ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable --now pteroq

step
self_signed "$PANEL_FQDN" "$PUBLIC_IP"

cat > /etc/nginx/sites-available/storiza.conf <<NGINX
server {
    listen 80;
    server_name ${PANEL_FQDN} _;

    location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    # No http2 and no [::] on purpose: the directive spelling changed in nginx
    # 1.25, and a host with IPv6 off cannot bind [::]. Either one would fail
    # the config test and take the whole install down with it.
    listen 443 ssl;
    server_name ${PANEL_FQDN} _;

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;

    root ${PANEL_DIR}/public;
    index index.php;
    charset utf-8;

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log off;
    error_log /var/log/nginx/pterodactyl-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        # Without this Laravel builds asset URLs as http:// and the browser
        # blocks every one of them as mixed content.
        fastcgi_param HTTPS on;
        fastcgi_intercept_errors off;
        fastcgi_buffers 4 16k;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht { deny all; }
}
NGINX

mkdir -p /var/www/html
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/storiza.conf /etc/nginx/sites-enabled/storiza.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx "php${PHP_VER}-fpm"

certbot_try "$PANEL_DOMAIN" "$ADMIN_EMAIL"

step
command -v docker > /dev/null 2>&1 || curl -fsSL https://get.docker.com | bash
systemctl enable --now docker

mkdir -p /etc/pterodactyl /var/lib/pterodactyl/volumes /var/lib/pterodactyl/backups
curl -fsSLo /usr/local/bin/wings \
	"https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([ "$(uname -m)" = "x86_64" ] && echo amd64 || echo arm64)"
chmod u+x /usr/local/bin/wings

cat > /etc/systemd/system/wings.service <<'UNIT'
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
RestartSec=5s
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload

step
# An application API key has to be made through the panel's own model: the
# token is stored as a hash and shown exactly once, so a row inserted straight
# into api_keys can never authenticate. A throwaway artisan command is the
# only supported way in.
cd "$PANEL_DIR"
cat > app/Console/Commands/StorizaApiKey.php <<'PHPCMD'
<?php
namespace Pterodactyl\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Encryption\Encrypter;
use Illuminate\Support\Str;
use Pterodactyl\Models\ApiKey;
use Pterodactyl\Models\User;

class StorizaApiKey extends Command
{
    protected $signature = 'p:storiza:apikey';
    protected $description = 'Create an Application API key for the installer';

    public function handle(Encrypter $encrypter): int
    {
        $user = User::where('root_admin', true)->firstOrFail();
        $identifier = Str::random(ApiKey::IDENTIFIER_LENGTH);
        $token = Str::random(defined(ApiKey::class . '::KEY_LENGTH') ? ApiKey::KEY_LENGTH : 32);

        $key = new ApiKey();
        $key->user_id = $user->id;
        $key->key_type = ApiKey::TYPE_APPLICATION;
        $key->identifier = $identifier;
        $key->token = $encrypter->encrypt($token);
        $key->memo = 'storiza-install';
        foreach (['r_servers', 'r_nodes', 'r_allocations', 'r_users', 'r_locations',
                  'r_nests', 'r_eggs', 'r_database_hosts', 'r_server_databases'] as $perm) {
            $key->$perm = 3;  // read + write
        }
        $key->save();

        echo $identifier . $token;
        return 0;
    }
}
PHPCMD

php artisan clear-compiled > /dev/null 2>&1 || true
# stderr is left alone: when artisan refuses, its reason is the only thing
# that explains an empty key.
PANEL_API_KEY=$(php artisan p:storiza:apikey --no-interaction | tr -d '[:space:]')
rm -f app/Console/Commands/StorizaApiKey.php
php artisan clear-compiled > /dev/null 2>&1 || true
[ -n "$PANEL_API_KEY" ] || fail "The panel installed, but its API key could not be created."

systemctl restart nginx "php${PHP_VER}-fpm"
sleep 3

# Called over the panel's own hostname so Laravel sees the URL it expects, but
# resolved to this machine and without verification: the domain may not point
# here yet, and the certificate may be the self-signed one.
CURL=(curl -sk --resolve "${PANEL_FQDN}:443:127.0.0.1")
API_URL="${APP_URL}/api/application"

# Newer panel versions prefix application keys with ptla_, older ones do not.
AUTH=""
for prefix in "" "ptla_"; do
	if [ "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${API_URL}/users" \
		-H "Authorization: Bearer ${prefix}${PANEL_API_KEY}" \
		-H "Accept: application/json")" = "200" ]; then
		AUTH="Authorization: Bearer ${prefix}${PANEL_API_KEY}"
		PANEL_API_KEY="${prefix}${PANEL_API_KEY}"
		break
	fi
done
[ -n "$AUTH" ] || fail "The panel installed, but its API did not accept the key we created."

api() { # api <method> <path> [json body]
	local method=$1 path=$2 body=${3:-} out code attempt
	for attempt in 1 2 3 4 5; do
		if [ -n "$body" ]; then
			out=$("${CURL[@]}" -w '\n%{http_code}' -X "$method" "${API_URL}${path}" \
				-H "$AUTH" -H "Content-Type: application/json" -H "Accept: application/json" -d "$body")
		else
			out=$("${CURL[@]}" -w '\n%{http_code}' -X "$method" "${API_URL}${path}" \
				-H "$AUTH" -H "Accept: application/json")
		fi
		code=$(printf '%s' "$out" | tail -1)
		case "$code" in
			2*) printf '%s' "$out" | sed '$d'; return 0 ;;
		esac
		sleep 3
	done
	fail "The panel's API kept refusing ${method} ${path} (HTTP ${code})."
}

LOCATION_ID=$(api GET "/locations" | _jq -r ".data[] | select(.attributes.short==\"${LOCATION_SHORT}\") | .attributes.id")
[ -n "$LOCATION_ID" ] || LOCATION_ID=$(api POST "/locations" \
	"{\"short\":\"${LOCATION_SHORT}\",\"long\":\"${LOCATION_LONG}\"}" | _jq -r '.attributes.id')

# The node is addressed by the name its certificate is actually valid for --
# the domain when Let's Encrypt issued one, the IP otherwise, which the
# self-signed certificate carries as a SAN. Get this wrong and every console
# in the panel fails to connect.
[ "$CERT_TRUSTED" = yes ] && NODE_FQDN="$PANEL_DOMAIN" || NODE_FQDN="$PUBLIC_IP"

NODE_ID=$(api GET "/nodes" | _jq -r ".data[] | select(.attributes.name==\"${NODE_NAME}\") | .attributes.id")
[ -n "$NODE_ID" ] || NODE_ID=$(api POST "/nodes" "{
	\"name\": \"${NODE_NAME}\",
	\"location_id\": ${LOCATION_ID},
	\"fqdn\": \"${NODE_FQDN}\",
	\"scheme\": \"https\",
	\"memory\": $(free -m | awk '/^Mem:/{print $2}'),
	\"memory_overallocate\": 0,
	\"disk\": $(df -BM / | awk 'NR==2{gsub("M","");print $4}'),
	\"disk_overallocate\": 0,
	\"upload_size\": 100,
	\"daemon_sftp\": ${SFTP_PORT},
	\"daemon_listen\": ${WINGS_PORT},
	\"behind_proxy\": false,
	\"maintenance_mode\": false
}" | _jq -r '.attributes.id')

# The panel writes /etc/letsencrypt/live/<fqdn>/ into the configuration
# whether or not the certificate is really there, so point Wings at the one
# nginx is actually serving.
api GET "/nodes/${NODE_ID}/configuration" \
	| WINGS_CERT="$SSL_CERT" WINGS_KEY="$SSL_KEY" python3 -c '
import json, os, sys, yaml
config = json.load(sys.stdin)
config.setdefault("api", {}).setdefault("ssl", {}).update(
    enabled=True, cert=os.environ["WINGS_CERT"], key=os.environ["WINGS_KEY"])
with open("/etc/pterodactyl/config.yml", "w") as f:
    yaml.safe_dump(config, f, default_flow_style=False)
' || fail "The node was created, but its Wings configuration could not be written."

step
# Game servers, then the ranges the common web and bot eggs expect.
for range in 25565:25575 3000:3015 5000:5010 8000:8010 8080:8090 6000:6010; do
	ports=$(seq "${range%%:*}" "${range##*:}" | sed 's/.*/"&"/' | paste -sd,)
	# In a subshell: `api` stops the script when it gives up, and a range that
	# will not take is a missing convenience, not a broken server.
	( api POST "/nodes/${NODE_ID}/allocations" "{\"ip\":\"0.0.0.0\",\"ports\":[${ports}]}" > /dev/null ) \
		|| echo "[storiza] allocations ${range} were not created -- add them from the panel if you need them"
done

step
# Optional: a failure here costs the customer a few one-click templates, not
# their server, so it never fails the install.
cd "$PANEL_DIR"
cat > app/Console/Commands/StorizaEggs.php <<'PHPCMD'
<?php
namespace Pterodactyl\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Arr;
use Pterodactyl\Models\Egg;
use Pterodactyl\Models\EggVariable;
use Pterodactyl\Models\Nest;
use Ramsey\Uuid\Uuid;

class StorizaEggs extends Command
{
    protected $signature = 'p:storiza:eggs';
    protected $description = 'Import the popular community eggs';

    private const BASE = 'https://raw.githubusercontent.com/parkervcp/eggs/master/';

    private array $sources = [
        'Generic' => [
            'generic/nodejs/egg-node-js-generic.json',
            'generic/python/egg-python-generic.json',
            'generic/java/egg-java.json',
            'generic/golang/egg-golang-generic.json',
            'generic/rust/egg-rust-generic.json',
            'generic/bun/egg-bun.json',
        ],
        'Bots' => [
            'bots/discord/redbot/egg-red.json',
            'bots/discord/sinusbot/egg-sinusbot.json',
            'bots/discord/jmusicbot/egg-j-music-bot.json',
        ],
        'Game Servers' => [
            'game_eggs/gta/fivem/egg-five-m.json',
            'game_eggs/steamcmd_servers/valheim/valheim_vanilla/egg-valheim.json',
            'game_eggs/steamcmd_servers/palworld/egg-palworld.json',
            'game_eggs/terraria/vanilla/egg-terraria-vanilla.json',
        ],
        'Databases' => [
            'database/nosql/mongodb/egg-mongo-d-b7.json',
            'database/redis/redis-7/egg-redis-7.json',
            'database/sql/postgres/egg-postgres16.json',
        ],
        'Monitoring' => [
            'software/uptime-kuma/egg-uptime-kuma.json',
        ],
    ];

    public function handle(): int
    {
        $ok = $failed = 0;

        foreach ($this->sources as $nestName => $paths) {
            $nest = Nest::where('name', $nestName)->first() ?: Nest::forceCreate([
                'uuid' => Uuid::uuid4()->toString(),
                'author' => 'install@storiza.store',
                'name' => $nestName,
                'description' => "Imported when this server was provisioned",
            ]);

            foreach ($paths as $path) {
                $json = @file_get_contents(self::BASE . $path);
                $egg = $json ? json_decode($json, true) : null;
                if (!$egg || !isset($egg['meta']['version'])) {
                    $failed++;
                    continue;
                }

                $name = Arr::get($egg, 'name', basename($path, '.json'));
                if (Egg::where('nest_id', $nest->id)->where('name', $name)->exists()) {
                    continue;
                }

                // Older eggs in the repository are still PTDL_v1.
                if ($egg['meta']['version'] === 'PTDL_v1') {
                    $images = $egg['images'] ?? [Arr::get($egg, 'image', 'nil')];
                    unset($egg['images'], $egg['image']);
                    $egg['docker_images'] = array_combine($images, $images);
                    $egg['variables'] = array_map(
                        fn ($v) => array_merge($v, ['field_type' => 'text']),
                        $egg['variables'] ?? []
                    );
                }

                try {
                    $row = (new Egg())->forceFill([
                        'uuid' => Uuid::uuid4()->toString(),
                        'nest_id' => $nest->id,
                        'author' => Arr::get($egg, 'author', 'unknown@unknown.com'),
                        'name' => $name,
                        'description' => Arr::get($egg, 'description'),
                        'features' => Arr::get($egg, 'features'),
                        'docker_images' => Arr::get($egg, 'docker_images'),
                        'file_denylist' => collect(Arr::get($egg, 'file_denylist', []))->filter(),
                        'update_url' => Arr::get($egg, 'meta.update_url'),
                        'config_files' => Arr::get($egg, 'config.files'),
                        'config_startup' => Arr::get($egg, 'config.startup'),
                        'config_logs' => Arr::get($egg, 'config.logs'),
                        'config_stop' => Arr::get($egg, 'config.stop'),
                        'startup' => Arr::get($egg, 'startup'),
                        'script_install' => Arr::get($egg, 'scripts.installation.script'),
                        'script_entry' => Arr::get($egg, 'scripts.installation.entrypoint', 'bash'),
                        'script_container' => Arr::get($egg, 'scripts.installation.container', 'ghcr.io/parkervcp/installers:debian'),
                    ]);
                    $row->save();

                    foreach ($egg['variables'] ?? [] as $variable) {
                        EggVariable::query()->forceCreate(array_merge($variable, ['egg_id' => $row->id]));
                    }
                    $ok++;
                } catch (\Throwable $e) {
                    $failed++;
                }
            }
        }

        echo "imported {$ok}, failed {$failed}";
        return 0;
    }
}
PHPCMD

php artisan clear-compiled > /dev/null 2>&1 || true
echo "[storiza] eggs: $(php artisan p:storiza:eggs --no-interaction || echo 'import skipped')"
rm -f app/Console/Commands/StorizaEggs.php
php artisan clear-compiled > /dev/null 2>&1 || true

step
systemctl enable --now wings
sleep 4
systemctl is-active --quiet wings \
	|| echo "[storiza] Wings has not come up yet -- check: journalctl -u wings -f"

step
deny_ports 3306/tcp 6379/tcp

credentials <<CREDS
# Pterodactyl

| | |
|---|---|
| Panel | ${APP_URL} |
| Username | admin |
| Email | ${ADMIN_EMAIL} |
| Password | the one you chose when ordering |
| Certificate | ${CERT_NOTE} |

## Node

| | |
|---|---|
| Name | ${NODE_NAME} |
| Address | ${NODE_FQDN} |
| Wings | ${WINGS_PORT} |
| SFTP | ${SFTP_PORT} |

Allocations were created for 25565-25575 (game servers), 3000-3015, 5000-5010,
8000-8010, 8080-8090 and 6000-6010. Add more from Admin -> Nodes -> ${NODE_NAME}
-> Allocations, and open them with \`ufw allow <port>\`.

## Database

| | |
|---|---|
| Root password | ${DB_ROOT_PASS} |
| Panel database | ${DB_PANEL_NAME} |
| Panel user | ${DB_PANEL_USER} |
| Panel password | ${DB_PANEL_PASS} |

MariaDB and Redis are closed to the internet. They are reachable from this
server and from the game containers, which is all they need.

## API key

${PANEL_API_KEY}

Made during the install to register the node. Delete it from Admin -> API if
you do not want it, everything is already set up.

## Useful commands

    systemctl status wings pteroq nginx mariadb
    journalctl -u wings -f
    php ${PANEL_DIR}/artisan p:user:make
CREDS

echo "[storiza] Pterodactyl ready at ${APP_URL}"
