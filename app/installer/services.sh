#!/bin/sh

emailwiz_installer_finalize_services() {
	# Re-render after all Postfix/OpenDKIM settings are present and validate the
	# Dovecot syntax selected for the installed 2.3 or 2.4 release.
	emailwiz_installer_run_management system render --no-reload

	for service_name in opendkim dovecot postfix fail2ban; do
		printf 'Restarting %s...' "$service_name"
		service "$service_name" restart && printf ' ...done\n'
		systemctl enable "$service_name"
	done
}
