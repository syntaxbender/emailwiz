#!/bin/sh

domain_enable() {
	require_root
	require_database
	[ "$#" -ge 1 ] || die "domain enable requires DOMAIN."
	domain=$(normalize_domain "$1")
	shift
	validate_domain "$domain"
	no_reload=0
	while [ "$#" -gt 0 ]; do
		case "$1" in --no-reload) no_reload=1; shift ;; *) die "Unknown domain enable option: $1" ;; esac
	done
	domain_exists "$domain" || die "Domain does not exist: $domain"
	q_domain=$(sql_escape "$domain")
	selector=$(sql "SELECT dkim_selector FROM domains WHERE name = '$q_domain';")
	load_canonical_tls
	ensure_dkim_key "$domain" "$selector"
	sql "UPDATE domains SET enabled = 1, deleted_at = NULL WHERE name = '$q_domain';"
	if ! render_all; then
		sql "UPDATE domains SET enabled = 0, deleted_at = CURRENT_TIMESTAMP WHERE name = '$q_domain';" || true
		render_all || warn "Could not restore the previous generated configuration automatically."
		die "Configuration rendering failed; $domain remains disabled."
	fi
	[ "$no_reload" -eq 1 ] || reload_services
	say "Enabled domain $domain."
}
