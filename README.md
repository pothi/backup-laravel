# Backup Laravel

Laravel Backup Scripts - to take backup of DB and/or files via cli. Can be used to automate via cron.

## Requirements / Assumptions

- [fish shell](https://fishshell.com/)
- [wp-cli](https://wp-cli.org/)
- [aws-cli](https://aws.amazon.com/cli/)
- [gpg](https://www.gnupg.org/index.html) for encrypted backups (optional, but helps to comply with GDPR).
- enough disk space to hold local backups

## Assumptions

+ Laravel sites:
```
~/sites/example.com(/public)
~/sites/example.net(/public)
```
+ Each site contains:
```
~/sites/example.com/.env
~/sites/example.net/.env
```
+ Backups stored in:
```
~/backups/nightly/
~/backups/weekly/
~/backups/monthly/
```

**Supported SQL servers:**

    + MySQL
    + MariaDB



### Features:

+ Support for offsite backups in AWS S3.
+ internal email alert.
+ external email alert via AWS SES.
+ Ability to auto-update scripts.
