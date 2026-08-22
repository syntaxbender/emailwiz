#!/bin/sh

emailwiz_certbot_validate_acme_dns_client() {
	client_path=$1
	emailwiz_certbot_require_absolute_path "$client_path" "acme-dns-client path" || return 1
	if [ ! -f "$client_path" ] || [ -L "$client_path" ] || [ ! -x "$client_path" ]; then
		emailwiz_certbot_error "acme-dns-client must be an executable regular file, not a symlink: $client_path"
		return 1
	fi
	case "$client_path" in
		*[[:space:]]*) emailwiz_certbot_error "acme-dns-client path cannot contain whitespace: $client_path"; return 1 ;;
	esac
	if [ "${EMAILWIZ_TEST_MODE:-0}" != 1 ]; then
		if [ "$(stat -c %u "$client_path")" -ne 0 ]; then
			emailwiz_certbot_error "acme-dns-client must be owned by root: $client_path"
			return 1
		fi
		if [ -n "$(find -P "$client_path" -perm /022 -print)" ]; then
			emailwiz_certbot_error "acme-dns-client cannot be writable by group or others: $client_path"
			return 1
		fi
	fi
}

emailwiz_certbot_run_acme_dns() {
	hostname=$1
	acme_dns_client=$2
	emailwiz_certbot_validate_acme_dns_client "$acme_dns_client" || return 1
	printf '%s\n' "DNS-01 method selected: acme-dns-client." >&2
	if ! "$acme_dns_client" check -d "$hostname" >&2; then
		emailwiz_certbot_error "acme-dns-client registration check failed for $hostname."
		return 1
	fi
	cname_output=$(host -t CNAME "_acme-challenge.$hostname" 2>/dev/null || true)
	case "$cname_output" in
		*' is an alias for '*) ;;
		*) emailwiz_certbot_error "Public CNAME is missing for _acme-challenge.$hostname."; return 1 ;;
	esac
	apt-get install -y certbot >&2
	certbot certonly --manual --preferred-challenges dns \
		--manual-auth-hook "$acme_dns_client" --cert-name "$hostname" -d "$hostname" \
		--non-interactive --register-unsafely-without-email --agree-tos >&2
}
