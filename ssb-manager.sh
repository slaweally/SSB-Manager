#!/bin/bash

# Configuration file for backup settings
CONFIG_FILE="/etc/ssb-manager/ssb-manager.conf"

# --- Functions ---

# Function to log messages
log_message() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a "$LOG_FILE"
}

# Function to check free disk space
check_disk_space() {
    local path="$1"
    local required_gb="$2"
    local free_space_kb=$(df -k "$path" | awk 'NR==2 {print $4}')
    local free_space_gb=$((free_space_kb / 1024 / 1024))

    if (( free_space_gb < required_gb )); then
        log_message "ERROR: Not enough free space on $path. Required: ${required_gb}GB, Available: ${free_space_gb}GB."
        return 1
    fi
    log_message "INFO: Free space on $path: ${free_space_gb}GB. Required: ${required_gb}GB."
    return 0
}

# Function to delete oldest backup if space is low
manage_disk_space() {
    local backup_dir="$1"
    local min_free_gb="$2"
    local current_free_gb=$(df -k "$backup_dir" | awk 'NR==2 {print $4}' | xargs -I {} echo $(( {} / 1024 / 1024 )))

    if (( current_free_gb < min_free_gb )); then
        log_message "WARNING: Disk space low on $backup_dir (${current_free_gb}GB). Attempting to delete oldest backups."
        while (( current_free_gb < min_free_gb )); do
            local oldest_backup=$(find "$backup_dir" -maxdepth 1 -type d -name "backup_*" | sort | head -n 1)
            if [ -z "$oldest_backup" ]; then
                log_message "ERROR: No old backups found to delete in $backup_dir."
                break
            fi
            log_message "INFO: Deleting oldest backup: $oldest_backup"
            rm -rf "$oldest_backup"
            current_free_gb=$(df -k "$backup_dir" | awk 'NR==2 {print $4}' | xargs -I {} echo $(( {} / 1024 / 1024 )))
            log_message "INFO: Free space after deletion: ${current_free_gb}GB."
        done
    fi
}

# Function to backup databases
backup_databases() {
    local db_backup_dir="$1"
    local mysql_user="$2"
    local mysql_password="$3"
    local db_names=()

    mkdir -p "$db_backup_dir" || { log_message "ERROR: Could not create database backup directory: $db_backup_dir"; return 1; }

    log_message "INFO: Backing up MySQL databases..."

    # Get list of databases, excluding system databases
    db_names=($(mysql -u"$mysql_user" -p"$mysql_password" -e "SHOW DATABASES;" | grep -Ev "(Database|information_schema|performance_schema|mysql|sys)"))

    for db in "${db_names[@]}"; do
        log_message "INFO: Dumping database: $db"
        if mysqldump -u"$mysql_user" -p"$mysql_password" --single-transaction "$db" > "$db_backup_dir/$db.sql"; then
            log_message "INFO: Successfully dumped $db to $db_backup_dir/$db.sql"
        else
            log_message "ERROR: Failed to dump database: $db"
        fi
    done
    return 0
}

# Function to perform the backup
perform_backup() {
    local backup_type="$1" # daily, weekly, monthly
    local current_date=$(date +%Y%m%d)
    local current_week=$(date +%Y%W)
    local current_month=$(date +%Y%m)
    local destination_dir=""

    case "$backup_type" in
        "daily")
            destination_dir="${BACKUP_DIR}/daily/${current_date}"
            ;;
        "weekly")
            destination_dir="${BACKUP_DIR}/weekly/${current_week}"
            ;;
        "monthly")
            destination_dir="${BACKUP_DIR}/monthly/${current_month}"
            ;;
        *)
            log_message "ERROR: Invalid backup type specified: $backup_type"
            return 1
            ;;
    esac

    mkdir -p "$destination_dir" || { log_message "ERROR: Could not create backup destination directory: $destination_dir"; return 1; }
    log_message "INFO: Starting $backup_type backup to $destination_dir"

    # Check for minimum disk space before starting
    if ! check_disk_space "$BACKUP_DIR" "$MIN_FREE_SPACE_GB"; then
        log_message "ERROR: Not enough space for backup. Aborting."
        return 1
    fi

    # Manage disk space if it falls below the stop threshold
    manage_disk_space "$BACKUP_DIR" "$STOP_BACKUP_SPACE_GB"

    # Backup databases if enabled
    if [[ "$INCLUDE_DATABASE" == "true" ]]; then
        local db_backup_location="${destination_dir}/databases"
        if ! backup_databases "$db_backup_location" "$MYSQL_USER" "$MYSQL_PASSWORD"; then
            log_message "ERROR: Database backup failed. Continuing with file backup (if enabled)."
        fi
    fi

    # Backup site files (home directory)
    if [[ "$INCLUDE_SITE_FILES" == "true" ]]; then
        local site_backup_location="${destination_dir}/home_files"
        mkdir -p "$site_backup_location" || { log_message "ERROR: Could not create site files backup directory: $site_backup_location"; return 1; }

        log_message "INFO: Backing up home directory: $HOME_DIR to $site_backup_location"
        case "$BACKUP_OPTION" in
            "full")
                if rsync -avzh --delete "$HOME_DIR/" "$site_backup_location/"; then
                    log_message "INFO: Full backup of $HOME_DIR completed successfully."
                else
                    log_message "ERROR: Full backup of $HOME_DIR failed."
                    return 1
                fi
                ;;
            "new_files_only")
                if rsync -avzh --ignore-existing "$HOME_DIR/" "$site_backup_location/"; then
                    log_message "INFO: New files only backup of $HOME_DIR completed successfully."
                else
                    log_message "ERROR: New files only backup of $HOME_DIR failed."
                    return 1
                fi
                ;;
            "no_file_updates") # This generally means a full backup if no updates are detected, or simply a skip. For simplicity, we'll implement it as a full backup if there are changes. A "no updates, no backup" would require more complex logic like checking hashes or timestamps.
                log_message "WARNING: 'backup if no file updates' option is ambiguous. Performing a standard rsync for changed files."
                if rsync -avu --compare-dest="$site_backup_location" "$HOME_DIR/" "$site_backup_location/"; then
                    log_message "INFO: Backup based on file updates completed successfully."
                else
                    log_message "ERROR: Backup based on file updates failed."
                    return 1
                fi
                ;;
            *)
                log_message "ERROR: Invalid backup option: $BACKUP_OPTION. Skipping file backup."
                return 1
                ;;
        esac
    fi

    log_message "INFO: $backup_type backup to $destination_dir completed."
    return 0
}

# --- Installation and Configuration Functions ---

create_config_file() {
    log_message "INFO: Creating configuration file: $CONFIG_FILE"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat << EOF > "$CONFIG_FILE"
# ssb-manager Backup Configuration

# General Settings
BACKUP_DIR="/home/Backup"
LOG_FILE="/var/log/ssb-manager.log"
HOME_DIR="/home" # Directory to backup (e.g., /home for user directories, /var/www for web files)

# Disk Space Management (in GB)
MIN_FREE_SPACE_GB=15      # Minimum required free space to start a backup
STOP_BACKUP_SPACE_GB=5    # If free space falls below this, old backups will be deleted

# Backup Inclusions
INCLUDE_DATABASE="true"   # Set to "true" to include MySQL databases
INCLUDE_SITE_FILES="true" # Set to "true" to include home/site files

# MySQL Database Settings (Required if INCLUDE_DATABASE is "true")
MYSQL_USER="root"
MYSQL_PASSWORD="your_mysql_root_password" # Change this to a strong password or dedicated backup user!

# Backup Options for Files
# Options: full, new_files_only, no_file_updates (Note: 'no_file_updates' performs a smart sync)
BACKUP_OPTION="full"

# Cron Job Settings (These are examples, you will configure cron manually)
# DAILY_CRON_SCHEDULE="0 2 * * *"     # Every day at 2 AM
# WEEKLY_CRON_SCHEDULE="0 3 * * 0"    # Every Sunday at 3 AM
# MONTHLY_CRON_SCHEDULE="0 4 1 * *"   # First day of every month at 4 AM
EOF
    log_message "INFO: Configuration file created. Please review and edit $CONFIG_FILE."
    log_message "INFO: Remember to change 'your_mysql_root_password' in the config file!"
}

install_ssb_manager() {
    echo "--- Installing SSB-Manager ---"
    if [ -f "$CONFIG_FILE" ]; then
        log_message "WARNING: Configuration file already exists at $CONFIG_FILE. Skipping creation."
    else
        create_config_file
    fi

    echo ""
    echo "--- Setting up Cron Jobs ---"
    echo "Please add the following lines to your cron table to schedule backups:"
    echo "Edit cron with: crontab -e"
    echo ""
    echo "# Daily Backup (e.g., every day at 2 AM)"
    echo "0 2 * * * /bin/bash $(readlink -f "$0") daily >> /var/log/ssb-manager-daily.log 2>&1"
    echo ""
    echo "# Weekly Backup (e.g., every Sunday at 3 AM)"
    echo "0 3 * * 0 /bin/bash $(readlink -f "$0") weekly >> /var/log/ssb-manager-weekly.log 2>&1"
    echo ""
    echo "# Monthly Backup (e.g., first day of every month at 4 AM)"
    echo "0 4 1 * * /bin/bash $(readlink -f "$0") monthly >> /var/log/ssb-manager-monthly.log 2>&1"
    echo ""
    echo "Make sure the script is executable: chmod +x $(readlink -f "$0")"
    echo "--- Installation Complete ---"
    echo "Remember to customize $CONFIG_FILE and set up cron jobs."
}

# --- Main Script Logic ---

if [ "$1" == "install" ]; then
    install_ssb_manager
    exit 0
fi

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Please run '$0 install' to set up the configuration file."
    exit 1
fi

# Set default log file if not set in config
LOG_FILE=${LOG_FILE:-"/var/log/ssb-manager.log"}

# Check if a backup type is provided as an argument
if [ -z "$1" ]; then
    log_message "ERROR: No backup type specified. Usage: $0 [daily|weekly|monthly|install]"
    exit 1
fi

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR" || { log_message "CRITICAL: Could not create main backup directory: $BACKUP_DIR. Exiting."; exit 1; }

# Execute the backup
perform_backup "$1"

exit $?
