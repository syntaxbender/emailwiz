#!/bin/sh

# Compose the authenticator-specific helpers behind one stable interface.

# shellcheck source=certbot/common.sh
. "$EMAILWIZ_APP_DIR/helpers/installer/certbot/common.sh"
# shellcheck source=certbot/http.sh
. "$EMAILWIZ_APP_DIR/helpers/installer/certbot/http.sh"
# shellcheck source=certbot/acme_dns.sh
. "$EMAILWIZ_APP_DIR/helpers/installer/certbot/acme_dns.sh"
# shellcheck source=certbot/cloudflare.sh
. "$EMAILWIZ_APP_DIR/helpers/installer/certbot/cloudflare.sh"

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
			emailwiz_certbot_run_http "$hostname"
			;;
		dns-acme)
			if [ -n "$cloudflare_credentials" ]; then
				emailwiz_certbot_error "Cloudflare credentials can only be used with dns-cloudflare."
				return 1
			fi
			emailwiz_certbot_run_acme_dns "$hostname" "$acme_dns_client"
			;;
		dns-cloudflare)
			emailwiz_certbot_run_cloudflare "$hostname" "$cloudflare_credentials"
			;;
		*) emailwiz_certbot_error "Unknown Certbot authenticator: $authenticator"; return 1 ;;
	esac

	emailwiz_certbot_verify_output "$cert_dir" || return 1
	printf '%s\n' "$cert_dir"
}
