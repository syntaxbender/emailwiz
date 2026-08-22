#!/bin/sh

domain_delete() {
	require_root
	require_database
	[ "$#" -ge 1 ] || die "domain delete requires DOMAIN."
	domain=$(normalize_domain "$1")
	shift
	validate_domain "$domain"
	purge=0
	no_reload=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--purge) purge=1; shift ;;
			--no-reload) no_reload=1; shift ;;
			*) die "Unknown domain delete option: $1" ;;
		esac
	done
	domain_exists "$domain" || die "Domain does not exist: $domain"
	q_domain=$(sql_escape "$domain")
	users=$(sql "SELECT COUNT(*) FROM mail_users u JOIN domains d ON d.id = u.domain_id WHERE d.name = '$q_domain';")
	if [ "$purge" -eq 1 ] && [ "$users" -gt 0 ]; then
		die "Purge each user in $domain before purging the domain."
	fi
	was_active=0
	domain_is_active "$domain" && was_active=1
	if [ "$was_active" -eq 1 ] && [ "$(active_domain_count)" -le 1 ]; then
		die "Cannot disable the last active domain. Add or enable another domain first."
	fi
	sql "UPDATE domains SET enabled = 0, deleted_at = CURRENT_TIMESTAMP WHERE name = '$q_domain';"
	if [ "$was_active" -eq 1 ]; then
		if ! render_all; then
			sql "UPDATE domains SET enabled = 1, deleted_at = NULL WHERE name = '$q_domain';" || true
			render_all || warn "Could not restore the previous generated configuration automatically."
			die "Configuration rendering failed; $domain was re-enabled."
		fi
		[ "$no_reload" -eq 1 ] || reload_services
	fi
	if [ "$purge" -eq 1 ]; then
		sql "DELETE FROM domains WHERE name = '$q_domain';"
		safe_remove_dkim_dir "$domain"
	fi
	if [ "$purge" -eq 1 ]; then
		say "Purged domain $domain and its DKIM key. The system TLS certificate was retained."
	else
		say "Disabled domain $domain; mail data and DKIM key were retained."
	fi
}
