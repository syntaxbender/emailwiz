#!/bin/sh

emailwiz_installer_configure_fail2ban() {
	if [ ! -f /etc/fail2ban/jail.d/emailwiz.local ]; then
		echo "[postfix]
enabled = true
[postfix-sasl]
enabled = true
[sieve]
enabled = true
[dovecot]
enabled = true" > /etc/fail2ban/jail.d/emailwiz.local
	fi

	sed -i 's|^backend = auto$|backend = systemd|' /etc/fail2ban/jail.conf
}
