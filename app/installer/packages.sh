#!/bin/sh

emailwiz_installer_install_packages() {
	install_packages="postfix postfix-sqlite dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-sieve dovecot-sqlite sqlite3 opendkim opendkim-tools net-tools fail2ban bind9-host"
	if [ "$use_spamassassin" = yes ]; then
		install_packages="$install_packages spamassassin spamc"
	fi

	systemctl -q stop dovecot
	systemctl -q stop postfix
	# Package names intentionally expand as separate arguments.
	# shellcheck disable=SC2086
	apt-get purge '?config-files' -y $install_packages
	# Package names intentionally expand as separate arguments.
	# shellcheck disable=SC2086
	apt-get install -y $install_packages
}

emailwiz_installer_install_application() {
	install_prefix=${EMAILWIZ_INSTALL_PREFIX:-/usr/local}
	install_root=${EMAILWIZ_INSTALL_LIB_DIR:-$install_prefix/lib/emailwiz}
	install_sbin_dir=${EMAILWIZ_INSTALL_SBIN_DIR:-$install_prefix/sbin}
	install -d -m 0755 "$install_root"
	install -d -m 0755 "$install_sbin_dir"

	find "$EMAILWIZ_APP_DIR" -type d -print |
	while IFS= read -r source_dir; do
		relative_dir=${source_dir#"$EMAILWIZ_APP_DIR"}
		install -d -m 0755 "$install_root$relative_dir"
	done
	find "$EMAILWIZ_APP_DIR" -type f -name '*.sh' -print |
	while IFS= read -r source_file; do
		relative_file=${source_file#"$EMAILWIZ_APP_DIR"}
		install -m 0644 "$source_file" "$install_root$relative_file"
	done

	install -m 0755 "$EMAILWIZ_REPO_DIR/emailwizctl" "$install_sbin_dir/emailwizctl"
}

emailwiz_installer_run_management() {
	# Exercise the deployed module tree during installation, not the checkout
	# that launched the installer.
	"$install_sbin_dir/emailwizctl" "$@"
}
