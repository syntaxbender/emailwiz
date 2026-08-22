#!/bin/sh

emailwiz_installer_configure_opendkim() {
	echo 'Configuring OpenDKIM...'
	grep -q '127.0.0.1' /etc/postfix/dkim/trustedhosts 2>/dev/null ||
		echo '127.0.0.1
10.1.0.0/16' >> /etc/postfix/dkim/trustedhosts

	grep -q '^KeyTable' /etc/opendkim.conf 2>/dev/null || echo 'KeyTable file:/etc/postfix/dkim/keytable
SigningTable refile:/etc/postfix/dkim/signingtable
InternalHosts refile:/etc/postfix/dkim/trustedhosts' >> /etc/opendkim.conf

	sed -i '/^#Canonicalization/s/simple/relaxed\/simple/' /etc/opendkim.conf
	sed -i '/^#Canonicalization/s/^#//' /etc/opendkim.conf

	sed -i '/Socket/s/^#*/#/' /etc/opendkim.conf
	grep -q '^Socket\s*inet:12301@localhost' /etc/opendkim.conf || echo 'Socket inet:12301@localhost' >> /etc/opendkim.conf

	sed -i '/^SOCKET/d' /etc/default/opendkim && echo "SOCKET=\"inet:12301@localhost\"" >> /etc/default/opendkim

	echo 'Configuring Postfix with OpenDKIM settings...'
	postconf -e 'smtpd_sasl_security_options = noanonymous, noplaintext'
	postconf -e 'smtpd_sasl_tls_security_options = noanonymous'
	postconf -e "myhostname = $maildomain"
	postconf -e 'milter_default_action = accept'
	postconf -e 'milter_protocol = 6'
	postconf -e 'smtpd_milters = inet:localhost:12301'
	postconf -e 'non_smtpd_milters = inet:localhost:12301'
	postconf -e 'mailbox_command ='

	postconf -e 'smtpd_forbid_bare_newline = normalize'
	# This variable is expanded by Postfix, not by this shell.
	# shellcheck disable=SC2016
	postconf -e 'smtpd_forbid_bare_newline_exclusions = $mynetworks'

	/lib/opendkim/opendkim.service.generate
	systemctl daemon-reload
}
