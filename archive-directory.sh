#!/bin/env bash

# make sure the SAFE_TMP points to either:
# - a volatile (tmpfs) ramdisk
# - a traditional block device (magnetic hdd)
# - an encrypted location (efs)
# using an unencrypted flash based device makes this cryptographically unsafe

# unguarded commands are okay to fail
set +o errexit
# increase robustness
set -o nounset
set -o pipefail
[[ "${TRACE:-}" ]] && set -x

readonly SCRIPT_EPOCH=$EPOCHSECONDS
readonly \
	KEEP_DAYS=365 \
	SELF_REPLICATE=1 \
	DATA_REDUNDANCY=5 \
	NO_RSYNC=0 \
	VERBOSE=1 \
	SOURCE_PATH='/mnt/i' \
	BLK_TARGET_PATHS=(
		'/mnt/j'
		'/mnt/f/Users/zeno/Sync/backup/keepass'
		'/mnt/f/Users/zeno/OneDrive/_backup/keys'
	) \
	SCP_TARGET_PATHS=(
		'zeno@sirius.fritz.box:/volume1/homes/zeno/rsync_backup/keys'
		'zeno@sirius.fritz.box:/volume1/sync/GoogleDrive'
	) \
	SAFE_TMP='/mnt/g/cryptmp/' \
	ARCHIVE_NAME="keys_${SCRIPT_EPOCH}.tar.xz" \
	LOG_FILE="folder-backup_${SCRIPT_EPOCH}.log"

init_logger() {
	readonly LOG_CMD='printf "[%s]: %s\n" "$(date --rfc-3339=seconds)" "$*"'

	LOG_ABS="$(realpath "$LOG_FILE")"
	if [[ ! -w "$(dirname "$LOG_ABS")" ]]; then
		# using fallback log
		LOG_ABS="/tmp/folder-backup_${SCRIPT_EPOCH}.log"
	fi
	if (( VERBOSE > 0 )); then
		log() {
			eval "$LOG_CMD" | tee -a "$LOG_ABS"
		}
	else
		log() {
			eval "$LOG_CMD" >> "$LOG_ABS"
		}
	fi
}

create_temp() {
	log "creating temporary directory at ${SAFE_TMP}"
	if ! MYTMP="$(mktemp -qd --tmpdir="${SAFE_TMP}")"; then
		log "could not create a temporary directory at ${SAFE_TMP}"
		exit 1
	fi
	log "${MYTMP} created"

	readonly MYTMP \
		WORKING_DIR="${MYTMP}/${SCRIPT_EPOCH}"
	readonly ARCHIVE_SOURCE_PATH="${WORKING_DIR}/${ARCHIVE_NAME}.gpg"
}

remove_temp() {
	log 'deleting temporary files'
	if [[ -n "$MYTMP" ]]; then
	{
		command find "$MYTMP" -mindepth 1 -maxdepth 2 -type f -print0 \
		| while IFS= read -r -d '' file; do
			log "shredding ${file}"
			gcl shred "$file"
			log "removing ${file}"
			gcl rm "$file"
		done
		log "removing ${WORKING_DIR}"
		command find "$MYTMP" -mindepth 1 -maxdepth 1 -type d -exec rmdir {} +
		log "removing ${MYTMP}"
		gcl rmdir "$MYTMP"
	} 2>/dev/null
	fi
}

cleanup() {
	local err="${1:-}" \
		line="${2:-}" \
		linecallfunc="${3:-}" \
		command="${4:-}" \
		funcstack="${5:-}"

	if (( err != 0 )); then
		log "ERROR: line $line - command '$command' exited with status: $err."
		log "ERROR: In $funcstack called at line $linecallfunc."
		log "DEBUG: From function ${funcstack[0]} (line $linecallfunc)."
	fi

	remove_temp
}

gci() {
	# guard command interactive
	local -r invocation="$*"
	log "invoking ${invocation}"
	if ! command "$@"; then
		log "command $invocation failed."
		get_user_input "$invocation failed, proceed?"
	fi
}

gce() {
	# guard command exit
	local -r invocation="$*"
	log "invoking ${invocation}"
	if ! command "$@"; then
		log "command $invocation failed."
		exit 1
	fi
}

gcl() {
	# guard command log
	local -r invocation="$*"
	log "invoking ${invocation}"
	if ! command "$@"; then
		log "command $invocation failed."
	fi
}

get_user_input() {
	while read -p "${1} " yn; do
    	case $yn in
        	[Yy]* ) break;;
        	[Nn]* ) exit 1;;
        	* ) printf "Please answer yes or no.\n";;
    	esac
    done
}

require_command() {
	log "checking if ${1} is available"
	if ! hash "$1" &>/dev/null; then
		log "could not find ${1}"
		return 1
	fi
}

ensure_commands() {
	for c in "$@"; do
		if ! require_command "$c"; then
			log "${c} is essential, aborting"
			exit 1
		fi
	done
}

check_tools() {
	ensure_commands gpg xz find

	declare -g USE_RSYNC=1
	if (( NO_RSYNC == 0 )) && ! require_command rsync; then
		get_user_input "rsync not found, falling back to cp"
		log "falling back to cp for copying files due to missing rsync binary"
		USE_RSYNC=0
	fi

	declare -g USE_PAR=1
	if (( DATA_REDUNDANCY > 0 )) && ! require_command par2create; then
		get_user_input "par2create not found, skip recovery data creating?"
		log "skipping the creation of par2 recovery files due to missing par2 binary"
		USE_PAR=0
	fi
}

verify_path_exists() {
	log "verifying if path ${1} exists"
	if [[ ! -d "$1" ]]; then
		log "path ${1} does not exist"
		get_user_input "Path ${1} does not exist, proceed?"
		return 1
	fi
}

verify_file_exists() {
	log "verifying if file ${1} exists"
	if [[ ! -f "$1" ]]; then
		log "file ${1} does not exist"
		get_user_input "File ${1} does not exist, proceed?"
		return 1
	fi
}

verify_path_writable() {
	log "verifying if path ${1} is writable"
	if [[ ! -w "$1" ]]; then
		log "path ${1} is not writtable"
		get_user_input "Path ${1} is not writable, proceed?"
		return 1
	fi
}

verify_data_written() {
	log "verifying file integrity of ${2}"
	if ! cmp "$1" "$2"; then
		log "there was an error validating ${2}"
		get_user_input "There was an error validating ${2}, proceed?"
		return 1
	fi
}

safe_copy_file() {
	# $1 -> source file
	# $2 -> destination directory
	log "copying ${1} to ${2}"
	verify_file_exists "$1" \
		&& verify_path_exists "$2" \
		&& verify_path_writable "$2" \
		&& gce cp "$1" "$2" \
		&& verify_data_written "$1" "${2}/$(basename "${1}")"
}

safe_shallow_copy_dir() {
	if (( USE_RSYNC > 0 )); then
		verify_path_writable "$2" \
			&& gce rsync -qat "$WORKING_DIR" "$2" \
			&& gce rsync -qact "$WORKING_DIR" "$2"
	else
		log "invoking cp"
		verify_path_writable "${2}" \
		&& gce mkdir -p "${2}/${SCRIPT_EPOCH}"
		for f in "$1/"*; do
			safe_copy_file "$f" "${2}/${SCRIPT_EPOCH}"
		done
	fi
}

create_recovery_data() {
	pushd .
	log "creating recovery information with 5% redundancy"
	command cd "$WORKING_DIR" \
		&& gci par2create -q -q -r${DATA_REDUNDANCY} "$ARCHIVE_SOURCE_PATH"
	popd
}

create_archive_folder() {
	verify_path_exists "$SOURCE_PATH"
	gce mkdir -p "$WORKING_DIR"
	(command tar --exclude 'System Volume Information' -cf - -C "$SOURCE_PATH" . | command xz -q -9e --threads=0 -v > "${MYTMP}/${ARCHIVE_NAME}") 2>&1 | tee -a "$LOG_ABS"
#	local tar_status=${PIPESTATUS[0]}
	local -r tar_pipe_status=$?
	command gpg -q --symmetric --cipher-algo AES256 --output "${ARCHIVE_SOURCE_PATH}" "${MYTMP}/${ARCHIVE_NAME}" 2>&1 | tee -a "$LOG_ABS"
#	local gpg_status=${PIPESTATUS[0]}
	local -r gpg_pipe_status=$?

	if (( tar_pipe_status != 0 )); then
		log "tar or xz error: ${tar_pipe_status}"
		exit $tar_pipe_status
	fi
	if (( gpg_pipe_status != 0 )); then
		log "gpg error: ${gpg_pipe_status}"
		exit $gpg_pipe_status
	fi

	if (( USE_PAR > 0 )); then
		create_recovery_data
	fi

	if (( SELF_REPLICATE > 0 )); then
		log "copying myself as ${0}"
		safe_copy_file "${BASH_SOURCE[0]}" "${WORKING_DIR}"
	fi
}

blk_copy_callback() {
	# $1 -> target path
	log "copying archive folder"
	safe_shallow_copy_dir "$WORKING_DIR" "$1"
}

scp_copy_callback() {
	log "initiating archive folder remote copy to ${1}"
	gci scp -qr "$WORKING_DIR" "$1"
}

archive_cleanup_callback() {
	# $1 -> target path
	# $2 -> maximum directory age in days
	if [[ -d "$1" ]]; then
		log "cleaning up old archives at ${1}"
		command find "$1" -mindepth 1 -maxdepth 1 -type d -mtime +${2} -regextype posix-extended -regex "^${1}/[0-9]{10}$" -print0 \
			| while IFS= read -r -d '' dir; do
				log "removing directory ${dir} and all of its content"
				command rm -rf "$dir"
			done 2>/dev/null
	else
		log "invalid cleanup callback call, ${1} is not a directory"
	fi
}

apply_do_path() {
	# $1 -> target paths array name (ref)
	# $2 -> function pointer (ref)
	# $@:3 -> any other arguments that should be forwarded to the function
	local -n target_paths=$2
	local -r delegate=$1
	for path in "${target_paths[@]}"; do
		log "processing ${path}"
		local -r arg=$([[ -n ${*:3} ]] && printf "with argument(s) ${*:3}")
		log "applying function ${delegate}" "$arg"
		$delegate "$path" "${@:3}"
	done
}

process_targets() {
	# $1 -> target paths array name (ref)
	apply_do_path blk_copy_callback BLK_TARGET_PATHS
	apply_do_path archive_cleanup_callback BLK_TARGET_PATHS $KEEP_DAYS
	apply_do_path scp_copy_callback SCP_TARGET_PATHS
}

trap 'cleanup "${?}" "${LINENO}" "${BASH_LINENO}" "${BASH_COMMAND}" $(printf "::%s" ${FUNCNAME[@]:-})' EXIT SIGINT

init_logger
create_temp
check_tools
create_archive_folder
process_targets

#EOF