#!/bin/sh

emailwiz_installer_configure_spamassassin() {
	if [ "$use_spamassassin" = yes ]; then
		if [ -f /etc/default/spamassassin ]; then
			sed -i 's|^CRON=0|CRON=1|' /etc/default/spamassassin
			printf 'Restarting spamassassin...'
			service spamassassin restart && printf ' ...done\n'
			systemctl enable spamassassin
		elif [ -f /etc/default/spamd ]; then
			sed -i 's|^CRON=0|CRON=1|' /etc/default/spamd
			printf 'Restarting spamd...'
			service spamd restart && printf ' ...done\n'
			systemctl enable spamd
		else
			die 'Neither /etc/default/spamassassin nor /etc/default/spamd exists; SpamAssassin setup cannot continue.'
		fi
	else
		printf 'SpamAssassin was not requested; inbound mail will bypass local spam classification.\n'
	fi
}
