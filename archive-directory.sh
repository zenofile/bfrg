#!/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
[[ "${TRACE:-}" ]] && set -o xtrace

readonly SCRIPT_EPOCH=$EPOCHSECONDS
readonly \
	ARCHIVE_CLEANUP=1 \
	KEEP_DAYS=365 \
	SELF_REPLICATE=1 \
	SAFE_DELETE=1 \
	DATA_REDUNDANCY=5 \
	VERBOSE=1 \
	# SAFE_TMP should ideally point to an encrypted or volatile
	# location in order to avoid leaking data to the block device
	SAFE_TMP='/mnt/g/cryptmp/' \
	SOURCE_PATH='/mnt/i' \
	BLK_LOCAL_TARGETS=(
		'/mnt/h'
		'/mnt/f/Users/zeno/Sync/backup/keepass'
		'/mnt/f/Users/zeno/OneDrive/_backup/keys'
	) \
	SCP_REMOTE_TARGETS=(
	) \
	RSYNC_REMOTE_TARGETS=(
		'zeno@sirius.fritz.box:/volume1/homes/zeno/rsync_backup/keys'
		'zeno@sirius.fritz.box:/volume1/sync/GoogleDrive'
	) \
	ARCHIVE_NAME="keys_${SCRIPT_EPOCH}.tar.xz" \
	LOG_FILE="archive-directory_${SCRIPT_EPOCH}.log"

# end of configuration section

_init_logger() {
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

_create_temp() {
	_log "creating temporary directory at ${SAFE_TMP}"
	if ! MYTMP="$(mktemp -qd --tmpdir="${SAFE_TMP}")"; then
		_log "could not create a temporary directory at ${SAFE_TMP}"
		exit 1
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
		_gcl shred "$file"
	fi
	_log "removing ${file}"
	_gcl rm "$file"
}

_remove_temp() {
	_log 'deleting temporary files'
	if [[ -n "$MYTMP" ]]; then
	{
		command find "$MYTMP" -mindepth 1 -maxdepth 2 -type f -print0 \
		| while IFS= read -r -d '' file; do
			_secure_delete_file "$file"
		done
		_log "removing ${WORKING_DIR}"
		command find "$MYTMP" -mindepth 1 -maxdepth 1 -type d -exec rmdir {} +
		_log "removing ${MYTMP}"
		_gcl rmdir "$MYTMP"
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
}

_gci() {
	# guard command interactive
	local -r invocation="$*"
	_log "invoking ${invocation}"
	if ! command "$@"; then
		_log "command $invocation failed."
		_get_user_input "$invocation failed, proceed?"
	fi
}

_gce() {
	# guard command exit
	local -r invocation="$*"
	_log "invoking ${invocation}"
	if ! command "$@"; then
		_log "command $invocation failed."
		exit 1
	fi
}

_gcl() {
	# guard command _log
	local -r invocation="$*"
	_log "invoking ${invocation}"
	if ! command "$@"; then
		_log "command $invocation failed."
	fi
}

_get_user_input() {
	while read -p "${1} " yn; do
    	case $yn in
        	[Yy]* ) break;;
        	[Nn]* ) exit 1;;
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
			exit 1
		fi
	done
}

_check_tools() {
	_ensure_commands gpg xz find

	declare -g USE_RSYNC=1 USE_SCP=1

	if ! _require_command rsync; then
		# rsync was at least implicitly requested but not found
		if (( ${#RSYNC_REMOTE_TARGETS[@]} > 0 )); then
			if _require_command ssh; then
				# try to gracefully fall back to SCP
				_log "rsync remote paths specified but no rsync binary found, falling back to scp"
				SCP_REMOTE_TARGETS+=("${RSYNC_REMOTE_TARGETS[@]}")
			else
				_get_user_input "rsync remote paths specified but no ssh binary found, continue anyway?"
			fi
		fi
		_log "skipping all rsync operations"
		USE_RSYNC=0
	fi

	if ! _require_command scp; then
		if (( ${#SCP_REMOTE_TARGETS[@]} > 0 )); then
			_get_user_input "scp remote paths exist but no scp binary found, continue anyway?"
		fi
		_log "skipping all scp operations"
		USE_SCP=0
	fi

	declare -g USE_PAR=1
	if (( DATA_REDUNDANCY > 0 )) && ! _require_command par2create; then
		_get_user_input "par2create not found, skip recovery data creating?"
		_log "skipping the creation of par2 recovery files due to missing par2 binary"
		USE_PAR=0
	fi
}

_verify_path_exists() {
	local -r path="$1"
	_log "verifying if path ${path} exists"
	if [[ ! -d "$path" ]]; then
		_log "path ${path} does not exist"
		_get_user_input "Path ${path} does not exist, continue?"
		return 1
	fi
}

_verify_file_exists() {
	local -r file="$1"
	_log "verifying if file ${file} exists"
	if [[ ! -f "$file" ]]; then
		_log "file ${file} does not exist"
		_get_user_input "File ${file} does not exist, continue?"
		return 1
	fi
}

_verify_path_writable() {
	local -r path="$1"
	_log "verifying if path ${path} is writable"
	if [[ ! -w "$path" ]]; then
		_log "path ${path} is not writable"
		_get_user_input "Path ${path} is not writable, continue?"
		return 1
	fi
}

_verify_data_written() {
	local -r src="$1" dst="$2"
	_log "verifying file integrity of ${dst}"
	if ! cmp "$src" "$dst"; then
		_log "there was an error validating ${dst}"
		_get_user_input "There was an error validating ${dst}, continue?"
		return 1
	fi
}

_safe_copy_file() {
	local -r src="$1" dst="$2"
	_log "copying ${src} to ${dst}"
	_verify_file_exists "$src" \
		&& _verify_path_exists "$dst" \
		&& _verify_path_writable "$dst" \
		&& _gce cp "$src" "$dst" \
		&& _verify_data_written "$src" "${dst}/$(basename "${src}")"
}

_safe_shallow_copy_dir() {
	local -r src="$1" dst="$2"
	if (( USE_RSYNC > 0 )); then
		_verify_path_writable "$dst" \
			&& _gce rsync -qat "$WORKING_DIR" "$dst" \
			&& _gce rsync -qact "$WORKING_DIR" "$dst"
	else
		_log "invoking cp"
		_verify_path_writable "${dst}" \
		&& _gce mkdir -p "${dst}/${SCRIPT_EPOCH}"
		for f in "$src/"*; do
			_safe_copy_file "$f" "${dst}/${SCRIPT_EPOCH}"
		done
	fi
}

_create_recovery_data() {
	pushd .
	_log "creating recovery information with 5% redundancy"
	command cd "$WORKING_DIR" \
		&& _gci par2create -q -q -r${DATA_REDUNDANCY} "$ARCHIVE_SOURCE_PATH"
	popd
}

_create_archive_folder() {
	_verify_path_exists "$SOURCE_PATH"
	_gce mkdir -p "$WORKING_DIR"
	(command tar --exclude 'System Volume Information' -cf - -C "$SOURCE_PATH" . | command xz -q -9e --threads=0 -v > "${MYTMP}/${ARCHIVE_NAME}") 2>&1 | command tee -a "$LOG_ABS"
	local -r tar_pipe_status=$?
	command gpg -q --symmetric --cipher-algo AES256 --output "${ARCHIVE_SOURCE_PATH}" "${MYTMP}/${ARCHIVE_NAME}" 2>&1 | command tee -a "$LOG_ABS"
	local -r gpg_pipe_status=$?

	if (( tar_pipe_status != 0 )); then
		_log "tar or xz error: ${tar_pipe_status}"
		exit $tar_pipe_status
	fi
	if (( gpg_pipe_status != 0 )); then
		_log "gpg error: ${gpg_pipe_status}"
		exit $gpg_pipe_status
	fi

	if (( USE_PAR > 0 )); then
		_create_recovery_data
	fi

	if (( SELF_REPLICATE > 0 )); then
		_log "copying myself as ${0}"
		_safe_copy_file "${BASH_SOURCE[0]}" "${WORKING_DIR}"
	fi
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

_archive_cleanup_callback() {
	local -r dst="$1" age=$2
	if [[ -d "$dst" ]]; then
		_log "cleaning up old archives at ${dst}"
		command find "$dst" -mindepth 1 -maxdepth 1 -type d -mtime +${age} -regextype posix-extended -regex "^${dst}/[0-9]{10}$" -print0 \
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
	if (( ARCHIVE_CLEANUP > 0 )); then
		_apply_do_path _archive_cleanup_callback BLK_LOCAL_TARGETS $KEEP_DAYS
	fi
}

trap '_cleanup "${?}" "${LINENO}" "${BASH_LINENO}" "${BASH_COMMAND}" $(printf "::%s" ${FUNCNAME[@]:-})' ERR EXIT SIGINT

_init_logger
_create_temp
_check_tools
_create_archive_folder
_process_targets

#EOF