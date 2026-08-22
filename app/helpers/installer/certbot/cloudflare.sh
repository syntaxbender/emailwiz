#!/bin/sh

emailwiz_certbot_validate_cloudflare_credentials() {
	credentials=$1
	emailwiz_certbot_require_absolute_path "$credentials" "Cloudflare credentials path" || return 1
	if [ ! -f "$credentials" ] || [ -L "$credentials" ]; then
		emailwiz_certbot_error "Cloudflare credentials must be a regular file, not a symlink: $credentials"
		return 1
	fi
	if [ "$(stat -c %a "$credentials")" != 600 ]; then
		emailwiz_certbot_error "Cloudflare credentials must have mode 0600: $credentials"
		return 1
	fi
	if [ "${EMAILWIZ_TEST_MODE:-0}" != 1 ]; then
		if [ "$(stat -c %u "$credentials")" -ne 0 ]; then
			emailwiz_certbot_error "Cloudflare credentials must be owned by root: $credentials"
			return 1
		fi
	fi
	if ! grep -Eq '^[[:space:]]*dns_cloudflare_api_token[[:space:]]*=[[:space:]]*[^[:space:]]+' "$credentials"; then
		emailwiz_certbot_error "Cloudflare credentials must contain a non-empty dns_cloudflare_api_token."
		return 1
	fi
}

emailwiz_certbot_run_cloudflare() {
	hostname=$1
	cloudflare_credentials=$2
	emailwiz_certbot_validate_cloudflare_credentials "$cloudflare_credentials" || return 1
	printf '%s\n' "DNS-01 method selected: Cloudflare API token." >&2
	apt-get install -y certbot python3-certbot-dns-cloudflare >&2
	if ! certbot plugins 2>/dev/null | grep -q 'dns-cloudflare'; then
		emailwiz_certbot_error "Certbot dns-cloudflare plugin is unavailable after installation."
		return 1
	fi
	certbot certonly --dns-cloudflare \
		--dns-cloudflare-credentials "$cloudflare_credentials" \
		--cert-name "$hostname" -d "$hostname" \
		--non-interactive --register-unsafely-without-email --agree-tos >&2
}
