#!/bin/bash
set -Eeuo pipefail

PG_CONF="/etc/pgbackrest/pgbackrest.conf"

log_message() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [BOOTSTRAP] $1" >&2
}

generate_ssl_cert() {
    local cert_dir="/var/lib/postgresql/certs"
    local key_file="$cert_dir/server.key"
    local cert_file="$cert_dir/server.crt"

    if [ ! -d "$cert_dir" ]; then
        mkdir -p "$cert_dir"
        chown "$PGUSER:$PGUSER" "$cert_dir"
        chmod 700 "$cert_dir"
    fi

    if [ ! -f "$key_file" ] || [ ! -f "$cert_file" ]; then
        log_message "🔐 Generating new self-signed SSL certificate..."
        openssl req -new -x509 -days 3650 -nodes -text -out "$cert_file" \
            -keyout "$key_file" -subj "/CN=postgres-server" 2>/dev/null

        chmod 600 "$key_file"
        chmod 600 "$cert_file"
        chown "$PGUSER:$PGUSER" "$key_file"
        chown "$PGUSER:$PGUSER" "$cert_file"
        log_message "✅ SSL Certificate generated."
    else
        log_message "🔐 SSL Certificate found. Skipping generation."
    fi
}

generate_ssl_cert

_shutdown() {
    log_message "🛑 Received termination signal. Forwarding to Postgres..."
    kill -TERM "$child_pid" 2>/dev/null
    wait "$child_pid"
}
trap _shutdown SIGTERM SIGINT

if [ "$1" != "postgres" ]; then
    log_message "⚠️ Not starting PostgreSQL server, passing through to original entrypoint..."
    exec docker-entrypoint.sh "$@"
fi

log_message "🚀 Starting Container Initialization..."
mkdir -p $PGDATA
mkdir -p "$PGBACK_DATA"
chown -R $PGUSER:$PGUSER $PGDATA
chown -R "$PGUSER:$PGUSER" "$PGBACK_DATA"
chown -R $PGUSER:$PGUSER /var/log/pgbackrest
chown -R $PGUSER:$PGUSER /etc/pgbackrest
chown -R $PGUSER:$PGUSER /tmp/pgbackrest

if [ ! -f "$PG_CONF" ]; then
    log_message "📄 No pgbackrest.conf found. Generating default local config..."

    cat <<EOF > "$PG_CONF"
[production]
pg1-path=$PGDATA
pg1-port=$PGPORT
pg1-user=postgres
pg1-database=postgres

[global]
start-fast=y
archive-async=y
archive-push-queue-max=5GiB
compress-type=bz2
compress-level=9
process-max=2
log-level-console=info
log-level-file=detail

repo1-bundle=y
repo1-block=y
repo1-path=$PGBACK_DATA
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=$PGBACK_PASSWORD
repo1-retention-archive=2
repo1-retention-full=2
repo1-retention-full-type=count
EOF
    chmod 640 "$PG_CONF"
    chown root:postgres "$PG_CONF"
fi

if [ -z "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
    log_message "🔍 Data directory is empty. Checking for existing backups with provided configuration..."
    if BACKUP_INFO=$(gosu $PGUSER pgbackrest --stanza=production info --output=json 2>/dev/null); then
        BACKUP_COUNT=$(echo "$BACKUP_INFO" | jq -r ".[] | select(.name==\"production\") | .backup | length // 0")
        
        if [ "$BACKUP_COUNT" -gt 0 ]; then
            log_message "♻️  Found $BACKUP_COUNT backup(s). Initiating RESTORE..."
            if gosu $PGUSER pgbackrest --stanza=production restore --log-level-console=info --delta; then
                log_message "✅ Restore successful."
            else
                log_message "❌ Restore failed! Check configuration."
                exit 1
            fi
        else
            log_message "🆕 Repository accessible but empty. Proceeding to fresh InitDB."
        fi
    else
        log_message "🆕 Repository check failed (likely uninitialized). Proceeding to fresh InitDB."
    fi
fi

if [ -z "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
    mkdir -p /docker-entrypoint-initdb.d
    cat <<EOF > /docker-entrypoint-initdb.d/99_pgbackrest_config.sh
#!/bin/bash
echo "Append pgbackrest config to postgresql.conf..."
cat <<CONF >> "\$PGDATA/postgresql.conf"
archive_mode = on
archive_command = 'pgbackrest --stanza=production archive-push %p'
archive_timeout = 300
wal_level = replica
max_wal_senders = 10

ssl=on
ssl_cert_file = '/var/lib/postgresql/certs/server.crt'
ssl_key_file = '/var/lib/postgresql/certs/server.key'

logging_collector = on
log_directory = '/var/log/pgbackrest/postgres'
log_filename = 'postgresql-%Y-%m-%d.log'
log_file_mode = 0777
log_rotation_age = 1d
log_truncate_on_rotation = on
CONF
cat <<CONF >> "\$PGDATA/pg_hba.conf"
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
hostssl all             all             all                     scram-sha-256
CONF
EOF
    chmod +x /docker-entrypoint-initdb.d/99_pgbackrest_config.sh
fi

if [ -z "$CRONFILE" ]; then
    CRONFILE="/etc/pgbackrest/cronjob"
fi
if [ ! -f $CRONFILE ]; then
    log_message "⏰ Generating default cron schedule..."
    cat <<EOF > $CRONFILE
0 1 * * 0 pgbackrest --stanza=production backup --repo=1 --type=full
0 1 * * 1-6 pgbackrest --stanza=production backup --repo=1 --type=diff
0 2-23 * * * pgbackrest --stanza=production backup --repo=1 --type=incr
EOF
fi
chown "$PGUSER:$PGUSER" $CRONFILE
log_message "⏰ Starting Supercronic daemon..."
gosu $PGUSER supercronic -debug -inotify $CRONFILE > /var/log/pgbackrest/supercronic.log 2>&1 &

(
    log_message "⏳ (Background) Waiting for PostgreSQL to be ready..."
    until pg_isready -U postgres -h 127.0.0.1 -q; do sleep 2; done
    log_message "✅ (Background) PostgreSQL is UP."
    if ! gosu $PGUSER pgbackrest --stanza=production check >/dev/null 2>&1; then
        log_message "⚙️ (Background) Stanza not found. Creating..."
        if gosu $PGUSER pgbackrest --stanza=production --log-level-console=info stanza-create; then
            log_message "✅ Stanza created. Triggering initial backup..."
            gosu $PGUSER pgbackrest --stanza=production --type=full --log-level-console=info backup || true
        else
            log_message "⚠️ Stanza creation failed (or was done by another node)."
        fi
    else
        log_message "✅ Stanza is healthy."
    fi
) &

log_message "🐘 Starting PostgreSQL..."
/usr/local/bin/docker-entrypoint.sh "$@" &
child_pid=$!
wait "$child_pid"
