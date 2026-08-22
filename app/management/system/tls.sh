#!/bin/sh

system_tls() {
	require_root
	require_database
	[ "$#" -ge 1 ] || die "system tls requires HOSTNAME."
	hostname=$(normalize_domain "$1")
	shift
	validate_domain "$hostname"
	cert_dir=''
	authenticator=''
	no_reload=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--cert-dir)
				[ "$#" -ge 2 ] || die "--cert-dir requires a value."
				cert_dir=$2
				shift 2
				;;
			--authenticator)
				[ "$#" -ge 2 ] || die "--authenticator requires a value."
				authenticator=$2
				shift 2
				;;
			--no-reload) no_reload=1; shift ;;
			*) die "Unknown system tls option: $1" ;;
		esac
	done
	[ -n "$cert_dir" ] || die "system tls requires --cert-dir DIR."
	validate_certificate_hostname "$cert_dir" "$hostname"
	if [ -z "$authenticator" ]; then
		authenticator=$(metadata_get certificate_authenticator || true)
		authenticator=${authenticator:-external}
	fi
	validate_certificate_authenticator "$authenticator"

	old_hostname=$(metadata_get canonical_mail_hostname || true)
	old_cert_dir=$(metadata_get canonical_cert_dir || true)
	old_authenticator=$(metadata_get certificate_authenticator || true)
	metadata_set canonical_mail_hostname "$hostname"
	metadata_set canonical_cert_dir "$cert_dir"
	metadata_set certificate_authenticator "$authenticator"

	if [ "$(active_domain_count)" -gt 0 ]; then
		if ! render_all; then
			if [ -n "$old_hostname" ] && [ -n "$old_cert_dir" ]; then
				metadata_set canonical_mail_hostname "$old_hostname"
				metadata_set canonical_cert_dir "$old_cert_dir"
				if [ -n "$old_authenticator" ]; then
					metadata_set certificate_authenticator "$old_authenticator"
				else
					metadata_delete certificate_authenticator
				fi
				render_all || warn "Could not restore the previous generated configuration automatically."
			else
				metadata_delete canonical_mail_hostname
				metadata_delete canonical_cert_dir
				metadata_delete certificate_authenticator
			fi
			die "Configuration rendering failed; canonical TLS metadata was rolled back."
		fi
		[ "$no_reload" -eq 1 ] || reload_services
	fi
	say "Canonical mail TLS identity set to $hostname using $cert_dir ($authenticator)."
}
