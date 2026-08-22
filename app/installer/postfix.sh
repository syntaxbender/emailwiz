#!/bin/sh

emailwiz_installer_configure_postfix() {
	echo "Configuring Postfix's main.cf..."

	# SMTP identity and local destinations.
	postconf -e "myhostname = $maildomain"
	postconf -e "mail_name = $domain"
	postconf -e "mydomain = $domain"
	# These variables are expanded by Postfix, not by this shell.
	# shellcheck disable=SC2016
	postconf -e 'mydestination = $myhostname, mail, localhost.localdomain, localhost, localhost.$mydomain'

	postconf -e "smtpd_tls_key_file=$certdir/privkey.pem"
	postconf -e "smtpd_tls_cert_file=$certdir/fullchain.pem"
	postconf -e "smtp_tls_CAfile=$certdir/cert.pem"
	postconf -e 'smtpd_tls_security_level = may'
	postconf -e 'smtp_tls_security_level = may'
	postconf -e 'smtpd_tls_auth_only = yes'

	postconf -e 'smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1'
	postconf -e 'smtp_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1'
	postconf -e 'smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1'
	postconf -e 'smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1'

	if [ "$allow_suboptimal_ciphers" = no ]; then
		postconf -e 'tls_preempt_cipherlist = yes'
		postconf -e 'smtpd_tls_exclude_ciphers = aNULL, LOW, EXP, MEDIUM, ADH, AECDH, MD5, DSS, ECDSA, CAMELLIA128, 3DES, CAMELLIA256, RSA+AES, eNULL'
	fi

	# Dovecot provides the SASL socket used by Postfix.
	postconf -e 'smtpd_sasl_auth_enable = yes'
	postconf -e 'smtpd_sasl_type = dovecot'
	postconf -e 'smtpd_sasl_path = private/auth'

	postconf -e 'smtpd_sender_login_maps = proxy:sqlite:/etc/postfix/emailwiz-sender-logins.cf'
	postconf -e 'smtpd_sender_restrictions = reject_sender_login_mismatch, permit_sasl_authenticated, permit_mynetworks, reject_unknown_reverse_client_hostname, reject_unknown_sender_domain'
	postconf -e 'smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination, reject_unknown_recipient_domain'
	postconf -e 'smtpd_relay_restrictions = permit_sasl_authenticated, reject_unauth_destination'
	postconf -e 'smtpd_helo_required = yes'
	postconf -e 'smtpd_helo_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname, reject_unknown_helo_hostname'

	postconf -e 'virtual_mailbox_domains = proxy:sqlite:/etc/postfix/emailwiz-virtual-domains.cf'
	postconf -e 'virtual_mailbox_maps = proxy:sqlite:/etc/postfix/emailwiz-virtual-mailboxes.cf'
	postconf -e 'virtual_transport = lmtp:unix:private/dovecot-lmtp'
	postconf -e 'recipient_delimiter = +'
	postconf -e 'mailbox_command ='

	postconf -e 'header_checks = regexp:/etc/postfix/header_checks'
	echo "/^Received:.*/     IGNORE
/^X-Originating-IP:/    IGNORE" >> /etc/postfix/header_checks

	emailwiz_installer_configure_postfix_master
}

emailwiz_installer_configure_postfix_master() {
	echo "Configuring Postfix's master.cf..."

	sed -i '/^\s*-o/d;/^\s*submission/d;/^\s*smtp/d;/^\s*spamassassin[[:space:]]/d;/^\s*user=debian-spamd[[:space:]]/d' /etc/postfix/master.cf

	echo "smtp unix - - n - - smtp
smtp inet n - y - - smtpd" >> /etc/postfix/master.cf

	if [ "$use_spamassassin" = yes ]; then
		echo "  -o content_filter=spamassassin" >> /etc/postfix/master.cf
	fi

	echo "
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_tls_auth_only=yes
  -o smtpd_tls_wrappermode=no
  -o smtpd_enforce_tls=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_sender_restrictions=reject_sender_login_mismatch
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject_unauth_destination
smtps     inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_mynetworks,permit_sasl_authenticated,reject" >> /etc/postfix/master.cf

	if [ "$use_spamassassin" = yes ]; then
		echo "spamassassin unix -     n       n       -       -       pipe
	  user=debian-spamd argv=/usr/bin/spamc -f -e /usr/sbin/sendmail -oi -f \${sender} -- \${recipient}" >> /etc/postfix/master.cf
	fi
}
