#!/usr/bin/env fish

set ver 2.1

### Variables ###

# for encryption
set passphrase

# the script assumes your sites are kept like ~/sites/example.com, ~/sites/example.net, ~/sites/example.org and so on.
# if you have a different pattern, such as ~/app/example.com, please change here.
set sites_path {$HOME}/sites

# possible values: public_html, public, dist, etc
set public_dir public

# Number of backups to keep
set NightlyBackupsToKeep 7
set WeeklyBackupsToKeep 4
set MonthlyBackupsToKeep 12

#-------- You may NOT want to edit below this line --------#

set backup_type db

# for debugging
# set -l fish_trace non_empty_value

set backups_folder $HOME/backups/$backup_type
set dir_nightly $backups_folder/nightly
set dir_weekly $backups_folder/weekly
set dir_monthly $backups_folder/monthly

# create necessary directories
test -d ~/backups      || mkdir ~/backups
test -d ~/log          || mkdir ~/log
test -d "$dir_nightly" || mkdir -p "$dir_nightly"
test -d "$dir_weekly"  || mkdir -p "$dir_weekly"
test -d "$dir_monthly" || mkdir -p "$dir_monthly"

set file_ext sql.gz

set script_name (status basename)
set fulldate (date +%F)
set timestamp (date +%F_%H-%M-%S)

set aws_profile default

# Variables to be used later in the script
set bucket_name
set domain

set unique_backup
set backup_symlink
set backup_by_date

set alertEmails
set site_root

set env_file .env
set env_path

set time_start
set time_end
# end of empty variables

set -x PATH ~/bin ~/.local/bin /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin
test -d /snap/bin; and set -a PATH /snap/bin

# main function {{{
function backup-laravel-db -d 'Create a DB dump and optionally store it offsite.'
    argparse --name=backup-laravel-db 'h/help' 'b/bucket=' 'x/exclude_uploads' 'o/only_offsite' 'e/email=' 's/success' 'v/version' 'u/update' 'p/profile=' -- $argv
    or return

    if set -q _flag_help
        __backup_db_print_help
        return 0
    end

    if set -q _flag_version
        __backup_print_version
        return 0
    end

    if set -q _flag_update
        __self_update
        return 0
    end

    if not set -q argv[1]
        # if no arguments given (min requirement is example.com)
        __backup_db_print_help
        return 1
    end

    set domain $argv[1]

    if set -q _flag_email
        set alertEmails $_flag_email
    end

    if set -q _flag_success
        set success_alert yes
    end

    if set -q _flag_profile
        set aws_profile $_flag_profile
    end

    # actual script begins here
    begin
        __backup_db_bootstrap
        __backup_db_local

        if set -q _flag_bucket
            __backup_db_offsite $_flag_bucket
        end

        __backup_db_cleanup
    end

end # end of backup-db as a function
# }}}

# print help {{{
function __backup_db_print_help
    printf '%s\n\n' "Take a database backup"

    printf 'Usage: %s [-b <bucket_name>] [-e <email-address>] [-s] [-p <WP path>] [-v] [-h] example.com\n\n' "$script_name"

    printf '\t%s\t%s\n' "-b, --bucket" "Name of the bucket for offsite backup (default: none)"
    printf '\t%s\t%s\n' "-e, --email" "Email/s to send success/failure alerts"
    printf '\t%s\t%s\n' "-s, --success" "Alert on successful (offsite) backup (default: alert only on failures)"
    printf '\t%s\t%s\n' "-p, --path" "Path to Laravel files (default: ~/sites/example.com/public)"
    printf '\t%s\t%s\n' "-v, --version" "Prints the version info"
    printf '\t%s\t%s\n' "-u, --update" "Update if a new version is available."
    printf '\t%s\t%s\n' "-h, --help" "Prints help"

    printf "\nFor more info, changelog and documentation... https://github.com/pothi/backup-laravel\n"
end
# }}}

function __backup_print_version
    echo $ver
end

# self-update {{{
function __self_update
    # 'status filename' - prints the script name including the path to it.
    set -l local_script (status filename)
    test -d ~/backups; or mkdir -p ~/backups
    # echo Current Script: $local_script
    # echo Script Name: $script_name

    # get the remote version & keep it in a temporary file
    set --global upstream_script (mktemp)
    trap 'rm "$upstream_script"' EXIT INT TERM
    # echo "Temp Remote Script: $upstream_script"
    curl -sSL -o $upstream_script https://raw.githubusercontent.com/pothi/backup-laravel/refs/heads/main/$script_name

    # display the version info
    set -l upstream_version (fish $upstream_script -v)
    echo Local Version: $ver

    if test $ver != $upstream_version
        echo Upstream Version: $upstream_version
        printf '%-66s' 'Taking a backup of this script into ~/backups dir'
        cp $local_script ~/backups/(status basename)-$ver
        echo done.

        printf '%-66s' "Updating..."
        # final steps
        cp $upstream_script $local_script
        echo done.
    else
        echo Nothing to update.
    end
end
# }}}

# boottstrap function {{{
function __backup_db_bootstrap
    # Define file names
    set unique_backup $dir_nightly/$domain-$timestamp.$file_ext
    set backup_symlink $dir_nightly/$domain-latest.$file_ext
    set backup_by_date $domain-$fulldate.$file_ext

    set site_root $sites_path/$domain
    set env_path $site_root/$env_file

    ### Some standard checks ###
    # [ -d "$site_root" ] || { echo >&2 "Laravel is not found at ${site_root}"; exit 1; }

    if not test -f "$env_path"
        echo >&2 ".env file not found at $env_path"
        exit 1
    end

    # check for backup dir
    if test ! -d "$dir_nightly"
        echo >&2 "dir_nightly is not found at $dir_nightly This script can't create it, either!"
        echo >&2 You may create it manually and re-run this script.
        exit 1
    end

    command -q aws ; or begin; echo >&2 "[Warn]: aws cli is not found in $PATH. Offsite backups will not be taken!"; end
    type -q mail ; or  echo >&2 "[Warn]: 'mail' command is not found in \$PATH; Email alerts will not be sent!"

    ### Actual Script Starts here...
    echo # Beginning of output
    echo "Backup started on $(date +%c)"
    echo
    set time_start (date +%s)
end
# }}}

function __env_get --argument key file
    grep "^$key=" "$file" \
        | head -n1 \
        | string replace "$key=" "" \
        | string trim -c '"' \
        | string trim
end

# local backup function {{{
function __backup_db_local
    # take the actual DB backup
    # 2>/dev/null to suppress any warnings / errors
    echo Please hold on while the backup is being taken...

    set db_connection (__env_get DB_CONNECTION $env_path)
    set db_host       (__env_get DB_HOST $env_path)
    set db_port       (__env_get DB_PORT $env_path)
    set db_name       (__env_get DB_DATABASE $env_path)
    set db_user       (__env_get DB_USERNAME $env_path)
    set db_pass       (__env_get DB_PASSWORD $env_path)

    if test "$db_connection" != "mysql"
        echo >&2 "Unsupported DB_CONNECTION: $db_connection"
        exit 1
    end

    if test -z "$db_port"
        set db_port 3306
    end

    if test -n "$passphrase"
        set unique_backup "$unique_backup".gpg

        env MYSQL_PWD="$db_pass" \
            mysqldump \
            --host="$db_host" \
            --port="$db_port" \
            --user="$db_user" \
            --single-transaction \
            --quick \
            --routines \
            --triggers \
            --no-tablespaces=true \
            "$db_name" \
            | gzip \
            | gpg --symmetric \
                --passphrase "$passphrase" \
                --batch \
                -o "$unique_backup"

    else

        env MYSQL_PWD="$db_pass" \
            mysqldump \
            --host="$db_host" \
            --port="$db_port" \
            --user="$db_user" \
            --single-transaction \
            --quick \
            --routines \
            --triggers \
            --no-tablespaces=true \
            "$db_name" \
            | gzip > "$unique_backup"

    end

    if test $status -eq 0
        echo Local backup is successful.
        echo
    else
        set msg "$script_name - [Error] Something went wrong while taking local backup!"
        printf "\n%s\n\n" "$msg"
        echo "$msg" | mail -s 'Backup Failure' root@localhost
        # echo "$msg" | mail -s 'Backup Failure' "$alertEmails"
        [ -f "$unique_backup" ] && rm -f "$unique_backup"
        exit 1
    end

    ln -fs "$unique_backup" "$backup_symlink"
end
# }}}

# offsite backup function {{{
function __backup_db_offsite -a bucket_name
    echo Sending the backup to offsite. It may take a while...
    aws --profile $aws_profile s3 cp $unique_backup s3://$bucket_name/$domain/$backup_type/$backup_by_date --only-show-errors
    if test $status -eq 0
        set msg "Offsite backup is successful."
        printf "\n%s\n\n" "$msg"
        if set -q success_alert
            echo "$script_name - $msg" | mail -s 'Offsite Backup Info' root@localhost
            # echo "$script_name - $msg" | mail -s 'Offsite Backup Info' -b "$alertEmails"
        end
    else
        set msg "$script_name - [Error] Something went wrong while taking offsite backup."
        printf "\n%s\n\n" "$msg"
        echo "$msg" | mail -s 'Offsite Backup Info' root@localhost
        # echo "$msg" | mail -s 'Offsite Backup Info' -b "$alertEmails"
    end
end
# }}}

# clean up {{{
function __backup_db_cleanup
    # Weekly backup - Mondays
    if test 1 -eq "$(date +%u)"
        cp $unique_backup $dir_weekly/$backup_by_date
        echo Weekly backup is taken.
        echo
    end

    # Monthly backup - 1st of each month
    if test 1 -eq "$(date +%e)"
        cp $unique_backup $dir_monthly/$backup_by_date
        echo Monthly backup is taken.
        echo
    end

    # Auto delete backups
    find -L $dir_nightly/ -type f -iname "$domain-*" -mtime +$NightlyBackupsToKeep               -exec rm {} \;
    find -L $dir_weekly/  -type f -iname "$domain-*" -mtime +$(math $WeeklyBackupsToKeep x 7)    -exec rm {} \;
    find -L $dir_monthly/ -type f -iname "$domain-*" -mtime +$(math $MonthlyBackupsToKeep x 31)  -exec rm {} \;

    set -l sizeH $(du -h $unique_backup | awk '{print $1}')
    # Display some info about the backup.
    echo Backup Folder: $dir_nightly
    echo Latest backup: $unique_backup
    echo
    echo "Backup size:   $sizeH"

    set time_end (date +%s)
    set runtime (math $time_end - $time_start)
    set runtime_minutes (math -s0 $runtime / 60)
    set runtime_seconds (math $runtime % 60)
    echo Execution time: $runtime_minutes minutes $runtime_seconds seconds.
    echo
end
# }}}

backup-laravel-db $argv 2>&1 | tee -a ~/log/(status basename | awk -F. '{print $1}').log

# vim: fileencoding=utf-8 : foldmethod=marker : ts=4 sts=4 sw=4 et
