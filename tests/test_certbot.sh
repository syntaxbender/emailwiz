#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/emailwiz-certbot-test.XXXXXX")
cleanup() {
	find -P "${test_root:?}" -xdev -depth -delete
}
trap cleanup EXIT HUP INT TERM

bin_dir="$test_root/bin"
live_root="$test_root/letsencrypt/live"
command_log="$test_root/commands.log"
mkdir -p "$bin_dir" "$live_root"
: > "$command_log"

cat > "$bin_dir/apt-get" <<'EOF'
#!/bin/sh
printf 'apt-get %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
printf 'mock apt output\n'
EOF

cat > "$bin_dir/netstat" <<'EOF'
#!/bin/sh
printf '%b' "${MOCK_NETSTAT_OUTPUT:-}"
EOF

cat > "$bin_dir/certbot" <<'EOF'
#!/bin/sh
printf 'certbot %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
if [ "${1:-}" = plugins ]; then
	printf '* dns-cloudflare\n'
	exit 0
fi
cert_name=''
while [ "$#" -gt 0 ]; do
	case "$1" in
		--cert-name) cert_name=$2; shift 2 ;;
		*) shift ;;
	esac
done
: "${cert_name:?missing --cert-name}"
cert_dir="${EMAILWIZ_LETSENCRYPT_LIVE_ROOT:?}/$cert_name"
mkdir -p "$cert_dir"
printf 'chain\n' > "$cert_dir/fullchain.pem"
printf 'key\n' > "$cert_dir/privkey.pem"
printf 'leaf\n' > "$cert_dir/cert.pem"
EOF

cat > "$bin_dir/host" <<'EOF'
#!/bin/sh
if [ "${MOCK_CNAME_AVAILABLE:-0}" = 1 ]; then
	printf '%s is an alias for test.auth.acme-dns.invalid.\n' "${3:?missing hostname}"
	exit 0
fi
exit 1
EOF

cat > "$bin_dir/acme-dns-client" <<'EOF'
#!/bin/sh
printf 'acme-dns-client %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
EOF

chmod +x "$bin_dir"/*

export PATH="$bin_dir:$PATH"
export EMAILWIZ_TEST_MODE=1
export EMAILWIZ_LETSENCRYPT_LIVE_ROOT="$live_root"
export MOCK_COMMAND_LOG="$command_log"

# shellcheck source=../lib/certbot.sh
. "$repo_dir/lib/certbot.sh"

assert_contains() {
	needle=$1
	file=$2
	grep -F -- "$needle" "$file" >/dev/null || {
		printf 'Expected to find %s in %s\n' "$needle" "$file" >&2
		exit 1
	}
}

reset_test() {
	: > "$command_log"
	unset MOCK_NETSTAT_OUTPUT MOCK_CNAME_AVAILABLE
}

reset_test
http_output="$test_root/http.out"
cert_dir=$(emailwiz_certbot_run mail.http.example http-01 "$bin_dir/acme-dns-client" '' 2> "$http_output")
[ "$cert_dir" = "$live_root/mail.http.example" ]
assert_contains 'HTTP-01 method selected: Certbot standalone' "$http_output"
assert_contains 'Emailwiz does not modify firewall rules' "$http_output"
assert_contains 'sudo ufw allow 80/tcp' "$http_output"
assert_contains 'apt-get install -y certbot' "$command_log"
assert_contains 'certbot certonly --standalone --cert-name mail.http.example' "$command_log"

reset_test
export MOCK_NETSTAT_OUTPUT='tcp 0 0 0.0.0.0:80 0.0.0.0:* LISTEN 123/nginx\n'
emailwiz_certbot_run mail.nginx.example http-01 "$bin_dir/acme-dns-client" '' >/dev/null 2> "$test_root/nginx.out"
assert_contains 'HTTP-01 method selected: Nginx' "$test_root/nginx.out"
assert_contains 'apt-get install -y certbot python3-certbot-nginx' "$command_log"
assert_contains 'certbot certonly --nginx --cert-name mail.nginx.example' "$command_log"

reset_test
export MOCK_NETSTAT_OUTPUT='tcp6 0 0 :::80 :::* LISTEN 456/apache2\n'
emailwiz_certbot_run mail.apache.example http-01 "$bin_dir/acme-dns-client" '' >/dev/null 2> "$test_root/apache.out"
assert_contains 'HTTP-01 method selected: Apache' "$test_root/apache.out"
assert_contains 'apt-get install -y certbot python3-certbot-apache' "$command_log"
assert_contains 'certbot certonly --apache --cert-name mail.apache.example' "$command_log"

reset_test
export MOCK_NETSTAT_OUTPUT='tcp 0 0 0.0.0.0:80 0.0.0.0:* LISTEN 789/custom-web\n'
if emailwiz_certbot_run mail.unknown.example http-01 "$bin_dir/acme-dns-client" '' >/dev/null 2>&1; then
	printf 'An unknown TCP/80 listener unexpectedly selected standalone mode.\n' >&2
	exit 1
fi

reset_test
export MOCK_NETSTAT_OUTPUT='tcp 0 0 0.0.0.0:80 0.0.0.0:* LISTEN 123/nginx\ntcp6 0 0 :::80 :::* LISTEN 456/apache2\n'
if emailwiz_certbot_run mail.ambiguous.example http-01 "$bin_dir/acme-dns-client" '' >/dev/null 2>&1; then
	printf 'Simultaneous Nginx and Apache listeners were unexpectedly accepted.\n' >&2
	exit 1
fi

reset_test
if emailwiz_certbot_run mail.no-cname.example dns-acme "$bin_dir/acme-dns-client" '' >/dev/null 2>&1; then
	printf 'acme-dns was unexpectedly accepted without its public CNAME.\n' >&2
	exit 1
fi

reset_test
export MOCK_CNAME_AVAILABLE=1
emailwiz_certbot_run mail.acme.example dns-acme "$bin_dir/acme-dns-client" '' >/dev/null 2> "$test_root/acme.out"
assert_contains 'DNS-01 method selected: acme-dns-client' "$test_root/acme.out"
assert_contains 'acme-dns-client check -d mail.acme.example' "$command_log"
assert_contains "--manual-auth-hook $bin_dir/acme-dns-client" "$command_log"
assert_contains '--preferred-challenges dns' "$command_log"

reset_test
credentials="$test_root/cloudflare.ini"
printf 'dns_cloudflare_api_token = test-token\n' > "$credentials"
chmod 0600 "$credentials"
emailwiz_certbot_run mail.cloudflare.example dns-cloudflare "$bin_dir/acme-dns-client" "$credentials" \
	>/dev/null 2> "$test_root/cloudflare.out"
assert_contains 'DNS-01 method selected: Cloudflare API token' "$test_root/cloudflare.out"
assert_contains 'apt-get install -y certbot python3-certbot-dns-cloudflare' "$command_log"
assert_contains "--dns-cloudflare-credentials $credentials" "$command_log"

chmod 0644 "$credentials"
if emailwiz_certbot_run mail.insecure.example dns-cloudflare "$bin_dir/acme-dns-client" "$credentials" \
	>/dev/null 2>&1; then
	printf 'Insecure Cloudflare credential permissions were unexpectedly accepted.\n' >&2
	exit 1
fi

if grep -Eq '^[[:space:]]*ufw[[:space:]]+allow[[:space:]]+(80|80/tcp)' \
	"$repo_dir/emailwiz.sh" "$repo_dir/lib/certbot.sh"; then
	printf 'The installer still modifies the TCP/80 UFW rule.\n' >&2
	exit 1
fi

if sh "$repo_dir/emailwiz.sh" --certbot-authenticator invalid >/dev/null 2>&1; then
	printf 'The installer unexpectedly accepted an invalid authenticator.\n' >&2
	exit 1
fi
if sh "$repo_dir/emailwiz.sh" --certbot-authenticator dns-cloudflare >/dev/null 2>&1; then
	printf 'The installer unexpectedly accepted dns-cloudflare without credentials.\n' >&2
	exit 1
fi

printf 'Certbot authenticator tests passed\n'
