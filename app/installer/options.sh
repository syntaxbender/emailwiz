#!/bin/sh

emailwiz_installer_usage() {
	cat <<'EOF'
Usage: emailwiz.sh [OPTIONS]

  --with-spamassassin     Install SpamAssassin and filter inbound SMTP mail.
  --without-spamassassin  Do not install or configure SpamAssassin (default).
  --certbot-authenticator METHOD
                          http-01 (default), dns-acme or dns-cloudflare.
  --acme-dns-client PATH  Absolute acme-dns-client path for dns-acme
                          (default: /usr/local/bin/acme-dns-client).
  --cloudflare-credentials FILE
                          Root-only INI file containing a Cloudflare API token.
EOF
}

emailwiz_installer_parse_options() {
	use_spamassassin=no
	certbot_authenticator=http-01
	acme_dns_client=/usr/local/bin/acme-dns-client
	acme_dns_client_explicit=0
	cloudflare_credentials=''
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--with-spamassassin) use_spamassassin=yes ;;
			--without-spamassassin) use_spamassassin=no ;;
			--certbot-authenticator)
				[ "$#" -ge 2 ] || { emailwiz_installer_usage >&2; die 'Missing value for --certbot-authenticator.'; }
				certbot_authenticator=$2
				shift
				;;
			--acme-dns-client)
				[ "$#" -ge 2 ] || { emailwiz_installer_usage >&2; die 'Missing value for --acme-dns-client.'; }
				acme_dns_client=$2
				acme_dns_client_explicit=1
				shift
				;;
			--cloudflare-credentials)
				[ "$#" -ge 2 ] || { emailwiz_installer_usage >&2; die 'Missing value for --cloudflare-credentials.'; }
				cloudflare_credentials=$2
				shift
				;;
			-h|--help) emailwiz_installer_usage; exit 0 ;;
			*) emailwiz_installer_usage >&2; die "Unknown option: $1" ;;
		esac
		shift
	done

	case "$certbot_authenticator" in
		http-01)
			[ "$acme_dns_client_explicit" -eq 0 ] || die '--acme-dns-client requires dns-acme.'
			[ -z "$cloudflare_credentials" ] || die '--cloudflare-credentials requires dns-cloudflare.'
			;;
		dns-acme)
			[ -z "$cloudflare_credentials" ] || die '--cloudflare-credentials cannot be combined with dns-acme.'
			;;
		dns-cloudflare)
			[ "$acme_dns_client_explicit" -eq 0 ] || die '--acme-dns-client cannot be combined with dns-cloudflare.'
			[ -n "$cloudflare_credentials" ] || die 'dns-cloudflare requires --cloudflare-credentials FILE.'
			;;
		*) die "Unknown Certbot authenticator: $certbot_authenticator" ;;
	esac
}
