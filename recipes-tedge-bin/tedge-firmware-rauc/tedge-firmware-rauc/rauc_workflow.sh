#!/bin/sh
set -e
FIRMWARE_NAME=
FIRMWARE_VERSION=
FIRMWARE_URL=
FIRMWARE_META_FILE=/etc/tedge/.firmware
MANUAL_DOWNLOAD=0
EXPECTED_PARTITION=

# Exit codes
OK=0
FAILED=1

# Detect if sudo should be used or not. It will be used if it is found
SUDO=""
if command -V sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

ACTION="$1"
shift

log() {
    msg="$(date +%Y-%m-%dT%H:%M:%S) [current=$ACTION] $*"
    echo "$msg" >&2

    # publish to pub for better resolution
    current_partition=$(get_current_partition)
    tedge mqtt pub -q 2 te/device/main///e/firmware_update "{\"text\":\"Firmware Workflow: [$ACTION] $*\",\"state\":\"$ACTION\",\"partition\":\"$current_partition\"}"
    sleep 1
}

local_log() {
    # Only log locally and don't push to the cloud
    msg="$(date +%Y-%m-%dT%H:%M:%S) [current=$ACTION] $*"
    echo "$msg" >&2
}

update_state() {
    echo ":::begin-tedge:::"
    echo "$1"
    echo ":::end-tedge:::"
    sleep 1
}

set_reason() {
    reason="$1"
    message=$(printf '{"reason":"%s"}' "$reason")
    update_state "$message"
}

#
# main
#
while [ $# -gt 0 ]; do
    case "$1" in
        --firmware-name)
            FIRMWARE_NAME="$2"
            shift
            ;;
        --firmware-version)
            FIRMWARE_VERSION="$2"
            shift
            ;;
        --url)
            FIRMWARE_URL="$2"
            shift
            ;;
        --expected-partition)
            EXPECTED_PARTITION="$2"
            shift
            ;;
    esac
    shift
done

wait_for_network() {
    #
    # Wait for network to be ready but don't block if still not available as the rauc commit
    # might be used to restore network connectivity.
    #
    attempt=0
    max_attempts=10
    # Network ready: 0 = no, 1 = yes
    ready=0
    local_log "Waiting for network to be ready, and time to be synced"

    while [ "$attempt" -lt "$max_attempts" ]; do
        # TIME_SYNC_ACTIVE=$(timedatectl | grep NTP | awk '{print $NF}')
        TIME_IN_SYNC=$(timedatectl | awk '/System clock synchronized/{print $NF}')
        case "${TIME_IN_SYNC}" in
            yes)
                ready=1
                break
                ;;
        esac
        attempt=$((attempt + 1))
        local_log "Network not ready yet (attempt: $attempt from $max_attempts)"
        sleep 30
    done

    # Duration can only be based on uptime since the device's clock might not be synced yet, so 'date' will not be monotonic
    duration=$(awk '{print $1}' /proc/uptime)

    local_log "Network: ready=$ready (after ${duration}s)"
    if [ "$ready" = "1" ]; then
        log "Network is ready after ${duration}s (from startup)"
        return 0
    fi

    # Don't send cloud message if it is not ready
    return 1
}

load_rauc_variables() {
    eval "$(rauc status --output-format shell)"
}

get_current_partition() {
    load_rauc_variables
    echo "$RAUC_SYSTEM_BOOTED_BOOTNAME"
}

get_next_partition() {
    [ "$1" = "A" ] && echo "B" || echo "A"
}

executing() {
    current_partition=$(get_current_partition)
    next_partition=$(get_next_partition "$current_partition")
    echo "---------------------------------------------------------------------------"
    echo "Firmware update: $current_partition -> $next_partition"
    echo "---------------------------------------------------------------------------"
    log "Starting firmware update. Current partition is $current_partition, so update will be applied to $next_partition"

    # Store the current and next partition so it can work out if a swap has occurred
    update_state "$(printf '{"partition":"%s","nextPartition":"%s"}\n' "$current_partition" "$next_partition")"
}

download() {
    url="$1"
    tedge_url="$url"

    # Auto detect based on the url if the direct url can be used or not
    case "$url" in
        */inventory/binaries/*)
            #
            # Change url to a local url using the c8y proxy
            #
            partial_path=$(echo "$url" | sed 's|https://[^/]*/||g')
            c8y_proxy_host=$(tedge config get c8y.proxy.client.host)
            c8y_proxy_port=$(tedge config get c8y.proxy.client.port)
            tedge_url="http://${c8y_proxy_host}:${c8y_proxy_port}/c8y/$partial_path"

            log "Converted to local url: $url => $tedge_url"
            ;;
    esac

    if [ "$MANUAL_DOWNLOAD" = 1 ]; then
        # Removing any older files to ensure space for next file to download
        # Note: busy box does not support -delete
        TEDGE_DATA=$(tedge config get data.path)
        find "$TEDGE_DATA" -name "*.firmware" -exec rm {} \;

        last_part=$(echo "$partial_path" | rev | cut -d/ -f1 | rev)
        local_file="$TEDGE_DATA/${last_part}.firmware"
        log "Manually downloading artifact from $tedge_url and saving to $local_file"
        wget -O "$local_file" "$tedge_url" >&2
        log "Downloaded file from: $tedge_url"
        update_state "$(printf '{"url":"%s"}\n' "$local_file")"
    else
        log "Using download url: $tedge_url"
        update_state "$(printf '{"url":"%s"}\n' "$tedge_url")"
    fi
}

install() {
    url="$1"
    log "Executing: rauc install '$url'"
    EXIT_CODE="$OK"

    # Get bundle info
    BUNDLE_INFO=$(rauc info "$url" --output-format=shell 2>/dev/null)
    IS_ROOT_FS_IMAGE=$(echo "$BUNDLE_INFO" | grep "RAUC_IMAGE_CLASS_[0-9]='rootfs'")

    $SUDO rauc install "$url" || EXIT_CODE="$?"

    case "$EXIT_CODE" in
        0)
            if [ -n "$IS_ROOT_FS_IMAGE" ]; then
                log "OK, RESTART required"
                EXIT_CODE=4
            else
                log "OK, no RESTART required"
            fi
            ;;
        *)
            log "ERROR. Unexpected return code"
            ;;
    esac
    exit "$EXIT_CODE"
}

verify() {
    log "Verifying: TODO: Assume ok"
    exit "$OK"
}

commit() {
    log "Executing: rauc status mark-good"
    EXIT_CODE="$OK"

    current_partition="$(get_current_partition)"

    if [ "$current_partition" != "$EXPECTED_PARTITION" ]; then
        EXIT_CODE=2
    else
        $SUDO rauc status mark-good || EXIT_CODE="$?"
    fi    

    case "$EXIT_CODE" in
        0)
            log "Commit successful. New default partition is $current_partition"

            # Save firmware meta information to file (for reading on startup during normal operation)
            local_log "Saving firmware info to $FIRMWARE_META_FILE"
            printf 'FIRMWARE_NAME=%s\nFIRMWARE_VERSION=%s\nFIRMWARE_URL=%s\n' "$FIRMWARE_NAME" "$FIRMWARE_VERSION" "$FIRMWARE_URL" > "$FIRMWARE_META_FILE"
            ;;
        2)
            log "Nothing to commit (update is not in progress)"

            # Still mark partition as good, otherwise it could end up having no good partitions
            $SUDO rauc status mark-good ||:
            set_reason "Nothing to commit (update is not in progress)"
            ;;
        *)
            log "rauc returned code: $EXIT_CODE. Rolling back to previous partition"
            set_reason "rauc returned code: $EXIT_CODE. Rolling back to previous partition"
            ;;
    esac
    exit "$EXIT_CODE"
}

rollback() {
    log "Executing: Rollback"
    $SUDO rauc status mark-bad
}

case "$ACTION" in
    executing) executing; ;;
    download) download "$FIRMWARE_URL"; ;;
    install) install "$FIRMWARE_URL"; ;;
    verify) verify; ;;
    commit) commit; ;;
    rollback) rollback; ;;
    restarted)
	    wait_for_network ||:
        log "Device has been restarted...continuing workflow. partition=$(get_current_partition)"
        ;;
    rollback_successful)
        log "Firmware update failed, but the rollback was successful. partition=$(get_current_partition)"
        ;;
    *)
        log "Unknown command. This script only accecpts: executing, download, install, verify, commit, rollback, rollback_successful"
        exit "$FAILED"
        ;;
esac

exit "$OK"
