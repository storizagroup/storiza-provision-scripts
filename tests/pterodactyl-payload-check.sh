#!/usr/bin/env bash
# Runs the shipped payload-reading block against fixtures. The installer's
# logging is stubbed, and so is jq (not installed on the dev box) -- only the
# parsing and the guards are under test.
set -uo pipefail
SCRIPT=panels/gamepanels/pterodactyl.sh
BLOCK=$(sed -n '/^PROVISION_DATA=/,/^log "Panel administrator/p' "$SCRIPT")
[ -n "$BLOCK" ] || { echo "block not found"; exit 1; }

step() { :; }; log() { :; }; err() { echo "ERR: $*"; return 1; }
jq() { python -c '
import json,sys
path,f = sys.argv[1].split(" // ")[0], sys.argv[2]
v = json.load(open(f))
for k in [p for p in path.split(".") if p]:
    v = (v or {}).get(k)
print("" if v is None else v)
' "$2" "$3"; }

run() { PROVISION_DATA="$TMP/$1" eval "$BLOCK"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

printf '%s' '{"vps":{"ip":{"address":"203.0.113.7"}},"inputs":{"admin_email":"me@example.com","admin_password":"hunter2hunter2","panel_domain":"panel.example.com"}}' > "$TMP/full.json"
printf '%s' '{"vps":{"ip":{"address":"203.0.113.7"}},"inputs":{"admin_email":"me@example.com","admin_password":"hunter2hunter2"}}' > "$TMP/minimal.json"
printf '%s' '{"vps":{"ip":{"address":"203.0.113.7"}},"inputs":{"panel_domain":"panel.example.com"}}' > "$TMP/broken.json"

APP_URL=""
run full.json
[ "$ADMIN_EMAIL" = "me@example.com" ] && [ "$APP_URL" = "http://panel.example.com" ] \
  && [ "$PANEL_FQDN" = "panel.example.com" ] && [ "$ASSIGNED_IP" = "203.0.113.7" ] \
  && [ "$ADMIN_USER" = "admin" ] && echo "full payload    -> ok" || { echo "full payload FAILED"; exit 1; }

APP_URL=""
run minimal.json
[ -z "$PANEL_DOMAIN" ] && [ "$APP_URL" = "" ] && echo "no domain       -> ok, IP fallback left to installer" || { echo "minimal FAILED"; exit 1; }

out=$(APP_URL=""; run broken.json 2>&1)
echo "$out" | grep -q "admin_email is missing" && echo "missing email   -> rejected" || { echo "broken FAILED: $out"; exit 1; }

out=$(APP_URL=""; run nope.json 2>&1)
echo "$out" | grep -q "not found" && echo "no payload file -> rejected" || { echo "missing-file FAILED: $out"; exit 1; }
