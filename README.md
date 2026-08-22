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
| Certbot | One Let's Encrypt certificate for the canonical mail hostname; HTTP-01, acme-dns and Cloudflare DNS-01 are supported |
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

Let's Encrypt HTTP-01 is the default authenticator. Emailwiz detects the
process actively listening on TCP/80 and selects the Nginx or Apache Certbot
plugin accordingly. If TCP/80 is unused, it selects Certbot standalone. An
unknown listener causes an error instead of an unsafe standalone attempt.

Emailwiz does not add or remove the TCP/80 UFW rule. In HTTP-01 mode it prints
a reminder that TCP/80 must be reachable through UFW and any hosting-provider
firewall. DNS-01 modes do not require TCP/80.

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
3. Ensure ports 25, 110, 465, 587, 993 and 995 are allowed by the hosting provider.
4. For HTTP-01 only, also allow inbound TCP/80 in UFW and the provider firewall.
5. Configure PTR/rDNS for the server's primary mail hostname.

The installer initializes SQLite, obtains one TLS certificate for the canonical
mail hostname, adds the initial domain, generates its DKIM key and prints the
required MX/SPF/DKIM/DMARC records. DNS output is retained under
`/var/lib/emailwiz/dns/`.

Self-signed certificate generation is not supported. The installer uses Let's
Encrypt by default. An externally managed certificate can still be attached
later with `emailwizctl system tls`.

### acme-dns DNS-01

Install `acme-dns-client`, register only the canonical hostname and create the
CNAME it requests before running Emailwiz:

```sh
sudo acme-dns-client register \
  -d mail.example.com \
  -s https://auth.acme-dns.example

sudo acme-dns-client check -d mail.example.com

sudo sh emailwiz.sh \
  --certbot-authenticator dns-acme \
  --acme-dns-client /usr/local/bin/acme-dns-client
```

The client must be an absolute, root-owned executable that is not writable by
group or other users. `_acme-challenge.mail.example.com` must publicly resolve
as the CNAME created during registration. The Certbot renewal lineage retains
the absolute authentication-hook path.

### Cloudflare DNS-01

Use a Cloudflare API token restricted to `Zone:DNS:Edit` for the relevant DNS
zone. Store it outside the repository:

```ini
# /etc/letsencrypt/credentials/cloudflare.ini
dns_cloudflare_api_token = REPLACE_WITH_TOKEN
```

Protect and pass that file to the installer:

```sh
sudo chmod 0600 /etc/letsencrypt/credentials/cloudflare.ini

sudo sh emailwiz.sh \
  --certbot-authenticator dns-cloudflare \
  --cloudflare-credentials /etc/letsencrypt/credentials/cloudflare.ini
```

The installer adds the matching Certbot Cloudflare plugin, verifies that the
credentials file is root-owned with mode `0600`, and never places the token in
command arguments, logs or SQLite. Certbot stores only the credentials-file
path in its renewal configuration. See the official
[`certbot-dns-cloudflare` documentation](https://certbot-dns-cloudflare.readthedocs.io/en/stable/).

The old standalone `adddomain.sh` command remains as a compatibility wrapper
for `emailwizctl domain add`.

## Domain management

All hosted domains use the canonical hostname selected during installation,
such as `mail.example.com`, for MX and client connections. Only that hostname
needs an A/AAAA record and TLS certificate. Every hosted domain still receives
its own DKIM key, SPF record and DMARC record.

```sh
sudo emailwizctl domain add example.net
sudo emailwizctl domain list
sudo emailwizctl domain list --all
```

To replace or externally manage the system certificate, configure it at the
system level and then render the services. The certificate must cover the
canonical hostname and its directory must contain `fullchain.pem` and
`privkey.pem`:

```sh
sudo emailwizctl system tls mail.example.com \
  --cert-dir /etc/custom-certs/mail.example.com
```

Domain deletion is soft by default. It disables reception/login while keeping
the DKIM key and every mailbox record:

```sh
sudo emailwizctl domain delete example.net
sudo emailwizctl domain enable example.net
```

Permanent deletion requires all users under the domain to be purged first:

```sh
sudo emailwizctl domain delete example.net --purge
```

`--purge` removes the database domain and its DKIM material. The canonical
system certificate is never owned by an individual domain and is therefore
never removed by domain deletion.

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

For `alice@example.net` use the full email address as the username and the
server's canonical hostname (here `mail.example.com`) for both protocols:

| Setting | Value |
| --- | --- |
| Username | `alice@example.net` |
| SMTP server | `mail.example.com` |
| SMTP port | 465 (implicit TLS) or 587 (STARTTLS) |
| IMAP server | `mail.example.com` |
| IMAP port | 993 |

The same hostname should also be used for PTR/rDNS and Postfix's SMTP
identity. Hosted address domains remain independent in SQLite even though they
share this transport identity.

## Tests

The integration suite uses temporary paths and does not modify system mail
configuration:

```sh
tests/test_emailwizctl.sh
tests/test_certbot.sh

# Optional: also parse both configs with the official Dovecot Docker images.
EMAILWIZ_DOCKER_TEST=1 tests/test_emailwizctl.sh
```

The suites cover all three Certbot authenticators, HTTP listener selection,
credential safeguards, both generated Dovecot syntax families, SQLite
mappings, canonical TLS with multiple hosted domains, UID/GID home mapping,
soft deletion and guarded purge behavior.
