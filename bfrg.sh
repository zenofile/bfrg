#!/usr/bin/env bash

# - SAFE_TMP should ideally point to an encrypted or volatile
#   location in order to avoid leaking data to the block device
# - ARCHIVE_CLEANUP operates only on BLK_LOCAL_TARGETS
# - Speedier GoogleDrive: https://rclone.org/drive/#making-your-own-client-id

#   variables to be defined in ${XDG_CONFIG_HOME:-~/.config}/backup/bfrg/config"
#   theoretically only SOURCE_PATHS is essential
#   examples:
#     SOURCE_PATHS=("~/Documents" "~/Pictures") \
#     BLK_LOCAL_TARGETS=('/media/data/backup' "/run/media/${USERNAME}/FLASHDRIVE/backup") \
#     SCP_REMOTE_TARGETS=('user@hostname:/data/backup') \
#     RSYNC_REMOTE_TARGETS=('user@hostname2:/data/backup') \
#     RCLONE_REMOTE_TARGETS=('OneDrive:_backup' 'GoogleDrive:_backup' 'Dropbox:_backup/secrets')

set -o nounset
set -o pipefail
set -o errexit
[[ ${TRACE:-} ]] && set -o xtrace

(( ${BASH_VERSINFO:-0} < 4 )) && { echo "script requires bash version >= 4"; exit 3; }
declare -i errors=0

readonly SCRIPT_EPOCH=${EPOCHSECONDS:-$(date '+%s')} \
            cfg="${XDG_CONFIG_HOME:-~/.config}/backup/bfrg/config"
            default_excludes=('System Volume Information' '*~' '#*#' '.#*' 'tmp' '.tmp' '.nv' 'GPUCache' '.ccache' '.cache' '.var')

# satisfy -o nounset 
declare -a SOURCE_PATHS=() BLK_LOCAL_TARGETS=() SCP_REMOTE_TARGETS=() RSYNC_REMOTE_TARGETS=() RCLONE_REMOTE_TARGETS=()

_die() {
    [[ -z ${1-} ]] && set -- 1
    printf "[%s]: Fatal error. %s\n" "${BASH_SOURCE[1]}" "${*:2}" >&2
    exit "$1"
}

if ! [[ -r $cfg ]]; then 
    _die "Can't source global config file: $cfg"
fi
source "$cfg" || _die

ARCHIVE_CLEANUP=${ARCHIVE_CLEANUP:-1}
KEEP_DAYS=${KEEP_DAYS:-365}
SELF_REPLICATE=${SELF_REPLICATE:-1}
SAFE_DELETE=${SAFE_DELETE:-1}
DATA_REDUNDANCY=${DATA_REDUNDANCY:-5}
VERBOSE=${VERBOSE:-1}
FAIL_SILENTLY=${FAIL_SILENTLY:-0}
SAFE_TMP="${SAFE_TMP:-/tmp}"
EXCLUDE_LIST=( "${EXCLUDE_LIST[@]:-${default_excludes[@]}}" )
ARCHIVE_NAME="${ARCHIVE_NAME:-keys_${SCRIPT_EPOCH}.tar.xz}"
LOG_FILE="${LOG_FILE:-bfrg-${SCRIPT_EPOCH}.log}"
COMPRESSOR_CMD="${COMPRESSOR_CMD:-xz}"
COMPRESSOR_OPT="${COMPRESSOR_OPT:--q -9e --threads=0 -v}"

_init_logger() {
    # shellcheck disable=SC2016
    readonly LOG_CMD='printf "[%s]: %s\n" "$(printf "%(%Y-%m-%d %T%z)T")" "$*"'

    LOG_ABS="$(realpath "$LOG_FILE")"
    if [[ ! -w "$(dirname "$LOG_ABS")" ]]; then
        # using fallback log
        LOG_ABS="/tmp/folder-backup_${SCRIPT_EPOCH}.log"
    fi
    if (( VERBOSE > 0 )); then
        _log() {
            eval "$LOG_CMD" | command tee -a "$LOG_ABS"
        }
    else
        _log() {
            eval "$LOG_CMD" >> "$LOG_ABS"
        }
    fi
}

pushd() {
    _log "pushing $(realpath "${1}") onto the stack"
    command pushd "$@" &> /dev/null
}
popd() {
    _log "restoring directory from stack"
    command popd &> /dev/null
}

_create_temp() {
    _log "creating temporary directory at ${SAFE_TMP}"
    if ! MYTMP="$(mktemp -qd --tmpdir="${SAFE_TMP}")"; then
        _log "could not create a temporary directory at ${SAFE_TMP}"
        _die 1
    fi
    _log "${MYTMP} created"

    readonly MYTMP \
             WORKING_DIR="${MYTMP}/${SCRIPT_EPOCH}"
    readonly ARCHIVE_SOURCE_PATH="${WORKING_DIR}/${ARCHIVE_NAME}.gpg"
}

_secure_delete_file() {
    local -r file="$1"
    if (( SAFE_DELETE > 0 )); then
        _log "shredding ${file}"
        _gc shred "$file"
    fi
    _log "removing ${file}"
    _gc rm "$file"
}

_remove_temp() {
    _log 'deleting temporary files'
    if [[ -n $MYTMP ]]; then
        {
            command find "$MYTMP" -mindepth 1 -maxdepth 2 -type f -print0 \
                | while IFS= read -r -d '' file; do
                _secure_delete_file "$file"
            done
            _log "removing ${WORKING_DIR}"
            command find "$MYTMP" -mindepth 1 -maxdepth 1 -type d -exec rmdir {} +
            _log "removing ${MYTMP}"
            _gc rmdir "$MYTMP"
        } 2>/dev/null
    fi
}

_cleanup() {
    local err="${1:-}" \
          line="${2:-}" \
          linecall="${3:-}" \
          cmd="${4:-}" \
          stack="${5:-}"

    if (( err != 0 )); then
        _log "ERROR: line $line - command '$cmd' exited with status: $err."
        _log "ERROR: In $stack called at line $linecall."
        _log "DEBUG: From function ${stack[0]} (line $linecall)."
    fi

    _remove_temp
    _gc sync
}

_gc() {
    # guard command interactive
    local -r invocation="$*"
    _log "invoking ${invocation}"
    if ! command "$@"; then
        _log "command $invocation failed."
        return 1
    fi
}

_gci() {
    if ! _gc "$@"; then
        _input_dispatch "$invocation failed, proceed?"
    fi
}

_gce() {
    if ! _gc "$@"; then
        _die 1 "command $invocation failed."
    fi
}

_input_dispatch() {
    if (( FAIL_SILENTLY == 0)); then
        (( errors++ ))
        _log "failing silently."
        return 0
    fi
    while read -r -p "${1} " yn; do
        case $yn in
            [Yy]* ) (( errors++ )); break;;
            [Nn]* ) _die 1;;
            * ) printf "Please answer yes or no.\n";;
        esac
    done
}

_require_command() {
    local -r cmd="$1"
    _log "checking if ${cmd} is available"
    if ! hash "$cmd" &>/dev/null; then
        _log "could not find ${cmd}"
        return 1
    fi
}

_ensure_commands() {
    for cmd in "$@"; do
        if ! _require_command "$cmd"; then
            _log "${cmd} is essential, aborting"
            _die 1
        fi
    done
}

_verify_path_exists() {
    local -r path="$1"
    _log "verifying if path ${path} exists"
    if [[ ! -d $path ]]; then
        _log "path ${path} does not exist"
        return 1
    fi
}

_verify_file_exists() {
    local -r file="$1"
    _log "verifying if file ${file} exists"
    if [[ ! -f $file ]]; then
        _log "file ${file} does not exist"
        return 1
    fi
}

_verify_path_writable() {
    local -r path="$1"
    _log "verifying if path ${path} is writable"
    if [[ ! -w $path ]]; then
        _log "path ${path} is not writable"
        return 1
    fi
}

_verify_data_written() {
    local -r src="$1" dst="$2"
    _log "verifying file integrity of ${dst}"
    if ! cmp "$src" "$dst"; then
        _log "there was an error validating ${dst}"
        return 1
    fi
}

# short wrappers with input dispatch
_vpei() { _verify_path_exists "$1" || _input_dispatch "Path ${1} does not exist, continue?"; }
_vfei() { _verify_file_exists "$1" || _input_dispatch "File ${1} does not exist, continue?"; }

_vpwi() { _verify_path_writable "$1" || _input_dispatch "Path ${1} is not writable, continue?"; }
_vdwi() { _verify_data_written "$1" "$2" || _input_dispatch "There was an error validating ${2}, continue?"; }

_check_targets() {
    _ensure_commands gpg find "${COMPRESSOR_CMD}"
    declare -g USE_RSYNC=1 USE_SCP=1 USE_RCLONE=1

    (( ${#BLK_LOCAL_TARGETS[@]} > 0 )) || _die 1 "no block target configured"

    if ! _require_command rsync; then
        # rsync was at least implicitly requested but not found
        if (( ${#RSYNC_REMOTE_TARGETS[@]} > 0 )); then
            if _require_command ssh; then
                # try to gracefully fall back to SCP
                _log "rsync remote paths specified but no rsync binary found, falling back to scp"
                SCP_REMOTE_TARGETS+=("${RSYNC_REMOTE_TARGETS[@]}")
            else
                _input_dispatch "rsync remote paths specified but no ssh binary found, continue anyway?"
            fi
        fi
        _log "skipping all rsync operations"
        USE_RSYNC=0
    fi

    if ! _require_command scp; then
        if (( ${#SCP_REMOTE_TARGETS[@]} > 0 )); then
            _input_dispatch "scp remote paths exist but no scp binary found, continue anyway?"
        fi
        _log "skipping all scp operations"
        USE_SCP=0
    fi

    if ! _require_command rclone; then
        if (( ${#RCLONE_REMOTE_TARGETS[@]} > 0)); then
            _input_dispatch "rclone remote paths exist but no rclone binary found, continue anyway?"
        fi
        _log "skipping all rclone operations"
        USE_RCLONE=0
    fi

    declare -g USE_PAR=1
    if (( DATA_REDUNDANCY > 0 )) && ! _require_command par2create; then
        _input_dispatch "par2create not found, skip recovery data creating?"
        _log "skipping the creation of par2 recovery files due to missing par2 binary"
        USE_PAR=0
    fi
}

_safe_copy_file() {
    local -r src="$1" dst="$2"
    _log "copying ${src} to ${dst}"
    _vfei "$src" \
        && _vpei "$dst" \
        && _vpwi "$dst" \
        && _gce cp "$src" "$dst" \
        && _vdwi "$src" "${dst}/$(basename "${src}")"
}

_safe_shallow_copy_dir() {
    local -r src="$1" dst="$2"
    if (( USE_RSYNC > 0 )); then
        _vpwi "$dst" \
            && _gce rsync -qat "$WORKING_DIR" "$dst" \
            && _gce rsync -qact "$WORKING_DIR" "$dst"
    else
        _log "invoking cp"
        _vpwi "${dst}" \
            && _gce mkdir -p "${dst}/${SCRIPT_EPOCH}"
        for f in "$src/"*; do
            _safe_copy_file "$f" "${dst}/${SCRIPT_EPOCH}"
        done
    fi
}

_create_recovery_data() {
    pushd .
    _log "creating recovery information with ${DATA_REDUNDANCY}% redundancy"
    command cd "$WORKING_DIR" \
        && _gci par2create -q -q -r"${DATA_REDUNDANCY}" "$ARCHIVE_SOURCE_PATH"
    popd || _die 1 "popd failed in _create_recovery_data"
}

_append_basename_element() {
    # contract: $1: outvalue nameref new array, $2: input array
    (( $# < 2 )) && _die 1 "${FUNCNAME[1]} function contract violated"
    local -ar array=("${@:2}")
    local -n newarr="$1"
    for i in "${array[@]}"; do
        newarr+=('-C' "$i" "$(basename "$i")" )
    done
}

_compile_exclude_file() {
    printf -v var "%s, " "${EXCLUDE_LIST[@]}"
    var="${var%??}"; _log "compiling tar exclude file with: ${var}"
    printf -v var "%s\n" "${EXCLUDE_LIST[@]}";
    printf "%s" "${var%?}" > "${MYTMP}/excludes.list"
}

_create_archive_folder() {
    (( ${#SOURCE_PATHS[@]} > 0 )) || _die 1 "no SOURCE_PATHS defined "
    for src_path in "${SOURCE_PATHS[@]}"; do
        _log "this is source: $src_path"
        if ! _verify_path_exists "$src_path"; then
            _log "${src_path} is essential for operation, aborting."
            _die 1 "invalid path ${src_path}"
        fi
    done
    
    _gce mkdir -p "$WORKING_DIR"
    _compile_exclude_file

    { command tar --exclude-from="${MYTMP}/excludes.list" --exclude-caches -cf - "${SOURCE_PATHS[@]}" \
        | eval "$COMPRESSOR_CMD $COMPRESSOR_OPT" > "${MYTMP}/${ARCHIVE_NAME}"; } 2>&1 | command tee -a "$LOG_ABS"
    local -r tar_pipe_status=$?
    command gpg -q --symmetric --cipher-algo AES256 --output "${ARCHIVE_SOURCE_PATH}" "${MYTMP}/${ARCHIVE_NAME}" 2>&1 \
        | command tee -a "$LOG_ABS"
    local -r gpg_pipe_status=$?

    if (( tar_pipe_status != 0 )); then
        _log "tar or compressor error: ${tar_pipe_status}"
        _die $tar_pipe_status
    fi
    if (( gpg_pipe_status != 0 )); then
        _log "gpg error: ${gpg_pipe_status}"
        _die $gpg_pipe_status
    fi

    if (( USE_PAR > 0 )); then
        _create_recovery_data
    fi

    if (( SELF_REPLICATE > 0 )); then
        _log "copying myself as ${0}"
        _safe_copy_file "${BASH_SOURCE[0]}" "${WORKING_DIR}"
    fi
}

_show_errors() {
    if (( errors > 0 )); then
        _log "total error count: ${errors}"
    fi
    return $errors
}

_blk_copy_callback() {
    local -r dst="$1"
    _log "copying archive folder"
    _safe_shallow_copy_dir "$WORKING_DIR" "$dst"
}

_scp_copy_callback() {
    local -r dst="$1"
    _log "initiating archive folder remote copy to ${dst}"
    _gci scp -qr "$WORKING_DIR" "$dst"
}

_rsync_copy_callback() {
    local -r dst="$1"
    _log "using rsync over ssh for remote copying ${dst}"
    _gci rsync -qzact -e ssh "$WORKING_DIR" "$dst"
}

_rclone_copy_callback() {
    local -r dst="$1"
    _log "using rclone for copying ${dst}"
    _gci rclone -q copy "$WORKING_DIR" "${dst}/${SCRIPT_EPOCH}"
    _log "verifying copied files"
    _gci rclone -q check --one-way "$WORKING_DIR" "${dst}/${SCRIPT_EPOCH}"
}

_archive_cleanup_callback() {
    local -r dst="$1" age=$2
    if [[ -d "$dst" ]]; then
        _log "cleaning up old archives at ${dst}"
        command find "$dst" -mindepth 1 -maxdepth 1 -type d -mtime +"${age}" -regextype posix-extended -regex "^${dst}/[0-9]{10}$" -print0 \
            | while IFS= read -r -d '' dir; do
            _log "removing directory ${dir} and all of its content"
            command rm -rf "$dir"
        done 2>/dev/null
    else
        _log "invalid _cleanup callback call, ${dst} is not a directory"
    fi
}

_apply_do_path() {
    # $1 -> target paths array name (ref)
    # $2 -> function pointer (ref)
    # $@:3 -> any other arguments that should be forwarded to the function
    local -n target_paths=$2
    local -r delegate=$1
    for path in "${target_paths[@]}"; do
        _log "processing ${path}"
        # shellcheck disable=SC2155
        local arg="$([[ -n ${*:3} ]] && printf " with argument(s) '%s'" "${*:3}")"
        _log "applying function ${delegate}${arg}"
        unset arg
        $delegate "$path" "${@:3}"
    done
}

_process_targets() {
    # $1 -> target paths array name (ref)
    _apply_do_path _blk_copy_callback BLK_LOCAL_TARGETS
    if (( USE_RSYNC > 0 )); then
        _apply_do_path _rsync_copy_callback RSYNC_REMOTE_TARGETS
    fi
    if (( USE_SCP > 0 )); then
        _apply_do_path _scp_copy_callback SCP_REMOTE_TARGETS
    fi
    if (( USE_RCLONE > 0 )); then
        _apply_do_path _rclone_copy_callback RCLONE_REMOTE_TARGETS
    fi
    if (( ARCHIVE_CLEANUP > 0 )); then
        _apply_do_path _archive_cleanup_callback BLK_LOCAL_TARGETS "$KEEP_DAYS"
    fi
}

if [[ -n ${DEBUG:-} ]]; then
    trap '_cleanup "${?}" "${LINENO}" "${BASH_LINENO}" "${BASH_COMMAND}" $(printf "::%s" ${FUNCNAME[@]:-})' ERR EXIT SIGINT
else
    trap '_cleanup 0' ERR EXIT SIGINT
fi

_init_logger
_create_temp
_check_targets
_create_archive_folder
_process_targets
_show_errors

#EOF
