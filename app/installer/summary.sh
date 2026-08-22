#!/bin/sh

emailwiz_installer_print_summary() {
	dns_records=$(cat "/var/lib/emailwiz/dns/$domain.txt")
	cp "/var/lib/emailwiz/dns/$domain.txt" "$HOME/dns_emailwizard"

	printf '%b' "\033[31m
 _   _
| \\ | | _____      ___
|  \\| |/ _ \\ \\ /\\ / (_)
| |\\  | (_) \\ V  V / _
|_| \\_|\\___/ \\_/\\_/ (_)\033[0m

Add these records on either your registrar's site or your DNS server:
\033[32m
$dns_records
\033[0m
NOTE: You may need to omit the \`.$domain\` portion at the beginning if
inputting them in a registrar's web interface.

Also, these are now saved to \033[34m~/dns_emailwizard\033[0m in case you want them in a file.

Once you do that, create at least one virtual mailbox with emailwizctl. Check the README for how to add users/accounts
and how to log in.\n"
}
