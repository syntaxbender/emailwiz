#!/bin/sh

# Certificate acquisition helpers sourced by emailwiz.sh.

emailwiz_certbot_error() {
	printf 'ERROR: %s\n' "$*" >&2
	return 1
}

emailwiz_certbot_require_absolute_path() {
	path=$1
	label=$2
	case "$path" in
		/*) ;;
		*) emailwiz_certbot_error "$label must be an absolute path: $path" ;;
	esac
}

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

emailwiz_certbot_http_method() {
	listeners=$(netstat -ltnp 2>/dev/null | awk '$4 ~ /:80$/ { print }')
	has_nginx=0
	has_apache=0
	case "$listeners" in *nginx*) has_nginx=1 ;; esac
	case "$listeners" in *apache*|*httpd*) has_apache=1 ;; esac
	if [ "$has_nginx" -eq 1 ] && [ "$has_apache" -eq 1 ]; then
		emailwiz_certbot_error "Both Nginx and Apache appear to listen on TCP/80; HTTP-01 selection is ambiguous."
	elif [ "$has_nginx" -eq 1 ]; then
		printf '%s\n' nginx
	elif [ "$has_apache" -eq 1 ]; then
		printf '%s\n' apache
	elif [ -z "$listeners" ]; then
		printf '%s\n' standalone
	else
		emailwiz_certbot_error "TCP/80 is occupied by an unsupported process. Free it for Certbot standalone or use Nginx/Apache."
	fi
}

emailwiz_certbot_run() {
	hostname=$1
	authenticator=$2
	acme_dns_client=$3
	cloudflare_credentials=$4
	live_root=${EMAILWIZ_LETSENCRYPT_LIVE_ROOT:-/etc/letsencrypt/live}
	cert_dir="$live_root/$hostname"

	case "$authenticator" in
		http-01)
			if [ -n "$cloudflare_credentials" ]; then
				emailwiz_certbot_error "Cloudflare credentials can only be used with dns-cloudflare."
				return 1
			fi
			printf '%s\n' "Emailwiz does not modify firewall rules for HTTP-01." >&2
			printf '%s\n' "Ensure inbound TCP/80 is allowed by UFW and any provider firewall (for example: sudo ufw allow 80/tcp)." >&2
			http_method=$(emailwiz_certbot_http_method) || return 1
			case "$http_method" in
				nginx)
					printf '%s\n' "HTTP-01 method selected: Nginx (active TCP/80 listener detected)." >&2
					apt-get install -y certbot python3-certbot-nginx >&2
					certbot certonly --nginx --cert-name "$hostname" -d "$hostname" \
						--non-interactive --register-unsafely-without-email --agree-tos >&2
					;;
				apache)
					printf '%s\n' "HTTP-01 method selected: Apache (active TCP/80 listener detected)." >&2
					apt-get install -y certbot python3-certbot-apache >&2
					certbot certonly --apache --cert-name "$hostname" -d "$hostname" \
						--non-interactive --register-unsafely-without-email --agree-tos >&2
					;;
				standalone)
					printf '%s\n' "HTTP-01 method selected: Certbot standalone (TCP/80 is currently unused)." >&2
					apt-get install -y certbot >&2
					certbot certonly --standalone --cert-name "$hostname" -d "$hostname" \
						--non-interactive --register-unsafely-without-email --agree-tos >&2
					;;
			esac
			;;
		dns-acme)
			if [ -n "$cloudflare_credentials" ]; then
				emailwiz_certbot_error "Cloudflare credentials can only be used with dns-cloudflare."
				return 1
			fi
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
			;;
		dns-cloudflare)
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
			;;
		*) emailwiz_certbot_error "Unknown Certbot authenticator: $authenticator"; return 1 ;;
	esac

	if [ ! -f "$cert_dir/fullchain.pem" ]; then
		emailwiz_certbot_error "Certificate chain was not created: $cert_dir/fullchain.pem"
		return 1
	fi
	if [ ! -f "$cert_dir/privkey.pem" ]; then
		emailwiz_certbot_error "Certificate key was not created: $cert_dir/privkey.pem"
		return 1
	fi
	if [ ! -f "$cert_dir/cert.pem" ]; then
		emailwiz_certbot_error "Leaf certificate was not created: $cert_dir/cert.pem"
		return 1
	fi
	printf '%s\n' "$cert_dir"
}
