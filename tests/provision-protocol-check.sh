#!/usr/bin/env bash
#
# Checks lib/provision.sh against a throwaway directory: the files it writes,
# and that every way a script can end reaches a terminal state. Installs
# nothing.
#
#     bash tests/provision-protocol-check.sh
#
set -euo pipefail

LIB=$(cd "$(dirname "$0")/.." && pwd)/lib/provision.sh
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

# A VPS has jq; a laptop may not. The fixtures below are flat enough that
# "the last key in the path" is an unambiguous lookup.
if ! command -v jq > /dev/null 2>&1; then
	mkdir -p "$ROOT/bin"
	cat > "$ROOT/bin/jq" <<'STUB'
#!/usr/bin/env bash
key=${2%% *}; key=${key##*.}
grep -o "\"$key\":\"[^\"]*\"" "$3" | head -1 | cut -d'"' -f4
STUB
	chmod +x "$ROOT/bin/jq"
	export PATH="$ROOT/bin:$PATH"
fi

fails=0
check() { # check <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "  ok   $1"
	else
		echo "  FAIL $1: expected [$2], got [$3]"
		fails=$((fails + 1))
	fi
}

# Runs a script body against a fresh state directory, returns its state file.
run() { # run <body>
	local dir="$ROOT/$RANDOM"
	mkdir -p "$dir"
	echo '{"vps":{"ip":{"address":"203.0.113.7"}},"inputs":{"admin_email":"a@b.c"}}' \
		> "$dir/provision.json"
	STORIZA_DIR="$dir" bash -c "
		. '$LIB'
		storiza_start 'Test' 'First step' 'Second \"quoted\" step'
		$1
	" > /dev/null 2>&1 || true
	STATE_DIR=$dir
}

echo "a run that finishes"
run 'step; echo hello; step; echo world'
check "steps written once, both of them" \
	'[{"id":1,"name":"First step"},{"id":2,"name":"Second \"quoted\" step"}]' \
	"$(cat "$STATE_DIR/steps")"
check "ends completed on the last step" \
	'{"state":"completed","current_step":2,"failure_reason":null}' \
	"$(cat "$STATE_DIR/state")"
check "stdout reached the log" "yes" \
	"$(grep -q '^hello$' "$STATE_DIR/logs" && echo yes || echo no)"

echo "a run that stops on a missing answer"
run 'step; need ".inputs.panel_domain"'
check "fails on the step it reached" \
	'{"state":"failed","current_step":1,"failure_reason":"panel_domain is required, and the order did not carry one."}' \
	"$(cat "$STATE_DIR/state")"

echo "a run that dies without saying why"
run 'step; step; false'
check "still reaches a terminal state" "failed" \
	"$(sed 's/.*"state":"\([a-z]*\)".*/\1/' "$STATE_DIR/state")"
check "names the step that died" "yes" \
	"$(grep -q 'quoted.* step failed (exit 1)' "$STATE_DIR/state" && echo yes || echo no)"

echo "a run with no payload"
mkdir -p "$ROOT/bare"
STORIZA_DIR="$ROOT/bare" bash -c ". '$LIB'; storiza_start 'Test' 'Only step'" > /dev/null 2>&1 || true
check "fails before touching the system" "yes" \
	"$(grep -q '"state":"failed","current_step":0' "$ROOT/bare/state" && echo yes || echo no)"

echo "the Docker gate a deny list writes"
mkdir -p "$ROOT/bin" "$ROOT/gate"
for stub in docker ufw; do printf '#!/usr/bin/env bash
exit 0
' > "$ROOT/bin/$stub"; done
printf '#!/usr/bin/env bash
echo "1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.7"
' > "$ROOT/bin/ip"
chmod +x "$ROOT/bin/docker" "$ROOT/bin/ufw" "$ROOT/bin/ip"
export PATH="$ROOT/bin:$PATH"
: > "$ROOT/gate/after.rules"
UFW_AFTER_RULES="$ROOT/gate/after.rules" bash -c "
	. '$LIB'
	_DENIED='8000/tcp 5353/udp 9000'
	_docker_gate
" > /dev/null 2>&1
check "splits port from protocol" "yes" 	"$(grep -q -- '-p tcp --dport 8000 -j DROP' "$ROOT/gate/after.rules" && echo yes || echo no)"
check "keeps a protocol that is not tcp" "yes" 	"$(grep -q -- '-p udp --dport 5353 -j DROP' "$ROOT/gate/after.rules" && echo yes || echo no)"
check "assumes tcp when none was given" "yes" 	"$(grep -q -- '-p tcp --dport 9000 -j DROP' "$ROOT/gate/after.rules" && echo yes || echo no)"
check "filters on the external interface only" "yes" 	"$(grep -q -- '-i eth0' "$ROOT/gate/after.rules" && echo yes || echo no)"
check "writes one replaceable block" "1" 	"$(grep -c '^# BEGIN STORIZA' "$ROOT/gate/after.rules")"

echo "every script declares as many steps as it takes"
for f in "$(dirname "$0")"/../{panels,applications}/*/*.sh; do
	[ -e "$f" ] || continue
	case "$f" in */_archive/*) continue ;; esac
	grep -q "^storiza_start" "$f" || continue
	declared=$(sed -n '/^storiza_start/,/^$/p' "$f" | grep -c '^	"')
	check "$(basename "$f")" "$declared" "$(grep -c '^step$' "$f")"
done

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
