#!/bin/sh

domain_add() {
	require_root
	require_database
	[ "$#" -ge 1 ] || die "domain add requires DOMAIN."
	domain=$(normalize_domain "$1")
	shift
	validate_domain "$domain"
	no_reload=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--no-reload) no_reload=1; shift ;;
			*) die "Unknown domain add option: $1" ;;
		esac
	done
	domain_exists "$domain" && die "Domain already exists. Use '$PROGRAM domain enable $domain' if it is disabled."

	load_canonical_tls
	selector=mail
	ensure_dkim_key "$domain" "$selector"

	q_domain=$(sql_escape "$domain")
	sql "INSERT INTO domains(name, dkim_selector) VALUES('$q_domain', '$selector');"
	if ! render_all; then
		sql "DELETE FROM domains WHERE name = '$q_domain';" || true
		if [ "$(active_domain_count)" -gt 0 ]; then
			render_all || warn "Could not restore the previous generated configuration automatically."
		fi
		die "Configuration rendering failed; the domain database row was rolled back."
	fi
	[ "$no_reload" -eq 1 ] || reload_services
	write_dns_records "$domain" "$CANONICAL_MAIL_HOSTNAME" "$selector"
}
