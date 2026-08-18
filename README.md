# Emailwiz

Emailwiz installs a small multi-domain mail server on Ubuntu. Postfix remains
the SMTP server, Dovecot provides IMAP/POP3, authentication and LMTP delivery,
and SQLite stores virtual domains and mailbox identities.

## Installed inventory

| Component | Purpose |
| --- | --- |
| Postfix + `postfix-sqlite` | SMTP, recipient checks, authenticated submission and SQLite lookup maps |
| Dovecot IMAP/POP3/LMTP + `dovecot-sqlite` | Client access, SQLite password authentication and delivery as the mapped Unix UID/GID |
| SQLite | Virtual domain, mailbox, password-hash and home-path database |
| OpenDKIM | A separate DKIM key and signing rule for every hosted domain |
| Certbot | A separate certificate for every `mail.<domain>` hostname |
| SpamAssassin (optional) | Inbound spam classification when explicitly enabled during installation |
| Pigeonhole Sieve | User filtering; moves SpamAssassin-marked messages into `Junk` when that option is enabled |
| Fail2ban | Postfix and Dovecot login protection |

Postfix is not replaced by SQLite. SQLite replaces the old PAM/Unix-account
mailbox database and supplies Postfix's virtual lookup tables.

## Supported Ubuntu and Dovecot versions

The installer requires Ubuntu 22.04 or newer and detects the installed version
with `dovecot --version`. It generates independent configurations for the 2.3
and 2.4 syntax families.

| Ubuntu release | Ubuntu package family | Generated configuration |
| --- | --- | --- |
| 22.04 LTS | Dovecot 2.3.16 | Dovecot 2.3 syntax and external SQLite config |
| 24.04 LTS | Dovecot 2.3.21 | Dovecot 2.3 syntax and external SQLite config |
| 25.10 | Dovecot 2.4.1 | Dovecot 2.4 syntax with version headers and inline SQLite settings |
| 26.04 LTS | Dovecot 2.4.2 | Dovecot 2.4 syntax with version headers and inline SQLite settings |

The package versions above follow the current [Ubuntu package
index](https://packages.ubuntu.com/en/dovecot-core). A PPA or backport is also
handled correctly because selection uses the Dovecot version, not the Ubuntu
codename. Versions outside the 2.3/2.4 families are rejected until a matching
configuration generator exists. Dovecot documents the incompatible 2.4 syntax
changes in its [2.3 to 2.4 upgrade
guide](https://doc.dovecot.org/2.4.2/installation/upgrade/2.3-to-2.4.html).

Run this after an operating-system upgrade to regenerate and validate the
configuration for the newly installed Dovecot version:

```sh
sudo emailwizctl system render
sudo emailwizctl system version
```

## Storage and identity model

A mailbox is a virtual email identity mapped to the home directory of one
existing Unix user:

```text
alice@example.com -> /home/mehmet -> UID/GID from /etc/passwd
```

Mail stays in the original Emailwiz layout:

```text
/home/mehmet/Mail
/home/mehmet/Mail/Inbox
```

The Unix account must already exist. Emailwiz never creates it and never reads
or copies its `/etc/shadow` password. Dovecot authenticates the full email
address against a hash in `/var/lib/emailwiz/emailwiz.sqlite3`, then uses the
stored UID/GID to access that user's mail files.

When a mailbox is created:

- `home_path` must exactly match one `/etc/passwd` home directory below `/home`.
- A missing `Mail` directory is created and assigned to that Unix UID/GID.
- An existing empty `Mail` directory is reused with a warning.
- An existing non-empty `Mail` directory causes an error and is never changed.
- Existing mail is not migrated automatically.

More than one virtual identity may point at the same home while its `Mail`
directory is empty. Those identities share the same physical mailbox. Purging
one shared identity removes only its database row; physical mail is retained
until the final identity using that home is purged.

## Installation

The installer now needs `emailwizctl`, so clone the repository instead of
downloading only `emailwiz.sh`:

```sh
git clone https://github.com/syntaxbender/emailwiz.git
cd emailwiz
sudo sh emailwiz.sh
```

SpamAssassin is disabled by default. Enable it explicitly if this server should
classify inbound port 25 mail locally:

```sh
sudo sh emailwiz.sh --with-spamassassin
```

Without that flag, the SpamAssassin packages, Postfix content filter and global
`X-Spam-Flag` to `Junk` Sieve rule are omitted. `--without-spamassassin` is also
accepted when automation should state the default choice explicitly.

Before installation:

1. Set `/etc/mailname` to the initial bare domain, such as `example.com`.
2. Point `mail.example.com` to the server with an A and/or AAAA record.
3. Ensure ports 25, 80, 110, 465, 587, 993 and 995 are allowed by the hosting provider.
4. Configure PTR/rDNS for the server's primary mail hostname.

The installer initializes SQLite, adds the initial domain, generates its DKIM
key, obtains its TLS certificate and prints the required MX/SPF/DKIM/DMARC
records. DNS output is retained under `/var/lib/emailwiz/dns/`.

For an isolated installation, set `selfsigned="yes"` near the top of
`emailwiz.sh` before running it. Initial and later domain certificates will then
be generated under `/etc/emailwiz/certs/`; public clients will not trust them
unless their CA/trust configuration is managed separately.

The old standalone `adddomain.sh` command remains as a compatibility wrapper
for `emailwizctl domain add`.

## Domain management

Each domain uses `mail.<domain>` as its MX/client hostname. Postfix and Dovecot
select that domain's certificate with TLS SNI. The hostname needs an A or AAAA
record before Certbot can issue the certificate.

```sh
sudo emailwizctl domain add example.net
sudo emailwizctl domain list
sudo emailwizctl domain list --all
```

If a certificate is managed externally, provide its directory. It must contain
`fullchain.pem` and `privkey.pem`:

```sh
sudo emailwizctl domain add example.net --cert-dir /etc/custom-certs/mail.example.net
```

Domain deletion is soft by default. It disables reception/login while keeping
the certificate, DKIM key and every mailbox record:

```sh
sudo emailwizctl domain delete example.net
sudo emailwizctl domain enable example.net
```

Permanent deletion requires all users under the domain to be purged first:

```sh
sudo emailwizctl domain delete example.net --purge
```

`--purge` removes the database domain and its DKIM material. It removes a
certificate only when it is inside an Emailwiz-managed Certbot or self-signed
location; external certificate directories are retained.

## Mailbox management

Create the Unix account yourself, then map the virtual mailbox to its home:

```sh
sudo useradd -m mehmet
sudo emailwizctl user add alice@example.com --home /home/mehmet
```

The password is prompted for without echoing. Automation can supply exactly
one line on standard input:

```sh
printf '%s\n' "$MAIL_PASSWORD" |
  sudo emailwizctl user add alice@example.com --home /home/mehmet --password-stdin
```

Other management commands:

```sh
sudo emailwizctl user list
sudo emailwizctl user list --domain example.com --all
sudo emailwizctl user passwd alice@example.com
sudo emailwizctl user delete alice@example.com
sudo emailwizctl user enable alice@example.com
sudo emailwizctl user delete alice@example.com --purge
```

Soft deletion only disables authentication and delivery. User purge deletes
the database identity and, for the final identity mapped to that home, exactly
`<home_path>/Mail`; it retains the Unix account and every other file in the
home directory. Symlinked or unexpected paths are rejected.

## Client settings

For `alice@example.com` use the full email address as the username:

| Setting | Value |
| --- | --- |
| Username | `alice@example.com` |
| SMTP server | `mail.example.com` |
| SMTP port | 465 (implicit TLS) or 587 (STARTTLS) |
| IMAP server | `mail.example.com` |
| IMAP port | 993 |

Per-domain certificates rely on client TLS SNI support. Current Thunderbird,
K-9, Apple Mail, Mutt and NeoMutt support it; very old clients such as Outlook
2013 do not. Dovecot lists the known compatibility caveats in its [SNI
documentation](https://doc.dovecot.org/2.4.3/core/config/ssl.html#with-client-tls-sni-server-name-indication-support).

## Tests

The integration suite uses temporary paths and does not modify system mail
configuration:

```sh
tests/test_emailwizctl.sh

# Optional: also parse both configs with the official Dovecot Docker images.
EMAILWIZ_DOCKER_TEST=1 tests/test_emailwizctl.sh
```

It covers both generated Dovecot syntax families, SQLite mappings, multi-domain
TLS maps, UID/GID home mapping, soft deletion and guarded purge behavior.
