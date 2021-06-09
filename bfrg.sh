#!/usr/bin/env bash
# vim: ft=bash ts=4 sw=4 sts=-1 noet

set -o nounset
set -o pipefail
set -o errexit

shopt -s lastpipe

[[ ${TRACE:-} ]] && set -o xtrace

(( ${BASH_VERSINFO:-0} < 4 )) && { echo 'script requires bash version >= 4'; exit 3; }
declare -i errors=0

readonly SCRIPT_EPOCH=${EPOCHSECONDS:-$(date '+%s')} \
			cfg=${XDG_CONFIG_HOME:-${HOME}/.config}/backup/bfrg/config
			default_excludes=('System Volume Information' '*~' '#*#' '.#*' 'tmp' '.tmp' '.nv' 'GPUCache' '.ccache' '.cache' '.var')

# satisfy -o nounset
declare -a SOURCE_PATHS=() BLK_LOCAL_TARGETS=() SCP_REMOTE_TARGETS=() RSYNC_REMOTE_TARGETS=() RCLONE_REMOTE_TARGETS=()

die() {
	[[ -z ${1-} ]] && set -- 1
	printf '[%s]: Fatal error. %s\n' "${BASH_SOURCE[1]}" "${*:2}" >&2
	exit "${1}"
}

if ! [[ -r ${cfg} ]]; then
	die "Can't source global config file: ${cfg}"
fi
# shellcheck disable=SC1090
source "${cfg}" || die

ARCHIVE_CLEANUP=${ARCHIVE_CLEANUP:-1}
KEEP_DAYS=${KEEP_DAYS:-365}
SELF_REPLICATE=${SELF_REPLICATE:-1}
SAFE_DELETE=${SAFE_DELETE:-1}
DATA_REDUNDANCY=${DATA_REDUNDANCY:-5}
VERBOSE=${VERBOSE:-1}
NON_INTERACTIVE=${NON_INTERACTIVE:-0}
ERROR_ABORT=${ERROR_ABORT:-0}
SAFE_TMP=${SAFE_TMP:-/tmp}
EXCLUDE_LIST=( "${EXCLUDE_LIST[@]:-${default_excludes[@]}}" )
ARCHIVE_NAME=${ARCHIVE_NAME:-archive_${SCRIPT_EPOCH}.tar.xz}
LOG_FILE=${LOG_FILE:-bfrg-${SCRIPT_EPOCH}.log}
RCLONE_TASKS=${RCLONE_TASKS:-2}
GPG_CIPHER=${GPG_CIPHER:-AES256}
GPG_DIGEST=${GPG_DIGEST:-SHA512}
GPG_MANGLE_MODE=${GPG_MANGLE_MODE:-3}
GPG_MANGLE_ITERATIONS=${GPG_MANGLE_ITERATIONS:-65011712}
[[ ! -v COMPRESSOR_CMD[@] ]] && COMPRESSOR_CMD=( xz --q -9e --threads=0 -v )

init_logger() {
	# shellcheck disable=SC2016
	readonly LOG_CMD='printf "[%s]: %s\n" "$(printf "%(%Y-%m-%d %T%z)T")" "$*"'

	LOG_ABS=$(realpath "${LOG_FILE}")
	if [[ ! -w $(dirname "${LOG_ABS}") ]]; then
		# using fallback log
		LOG_ABS=/tmp/folder-backup_${SCRIPT_EPOCH}.log
	fi
	if (( VERBOSE > 0 )); then
		log() {
			eval "${LOG_CMD}" | command tee -a "${LOG_ABS}"
		}
	else
		log() {
			eval "${LOG_CMD}" >> "${LOG_ABS}"
		}
	fi
}

pushd() {
	log "pushing $(realpath "${1}") onto the stack"
	command pushd "$@" &> /dev/null
}
popd() {
	log 'restoring directory from stack'
	command popd &> /dev/null
}

create_temp() {
	log "creating temporary directory at ${SAFE_TMP}"
	if ! MYTMP=$(mktemp -qd --tmpdir="${SAFE_TMP}"); then
		log "could not create a temporary directory at ${SAFE_TMP}"
		die 1
	fi
	log "${MYTMP} created"

	readonly MYTMP \
			 WORKING_DIR=${MYTMP}/${SCRIPT_EPOCH}
	readonly ARCHIVE_SOURCE_PATH=${WORKING_DIR}/${ARCHIVE_NAME}.gpg
}

secure_delete_file() {
	local -r file=${1}
	if (( SAFE_DELETE > 0 )); then
		log "shredding ${file}"
		gc shred "${file}"
	fi
	log "removing ${file}"
	gc rm "${file}"
}

remove_temp() {
	log 'deleting temporary files'
	if [[ -n ${MYTMP} ]]; then
		{
			command find "${MYTMP}" -mindepth 1 -maxdepth 2 -type f -print0 \
				| while IFS= read -r -d '' file; do
				secure_delete_file "${file}"
			done
			log "removing ${WORKING_DIR}"
			command find "${MYTMP}" -mindepth 1 -maxdepth 1 -type d -exec rmdir {} +
			log "removing ${MYTMP}"
			gc rmdir "${MYTMP}"
		} 2>/dev/null
	fi
}

cleanup() {
	local err=${1:-} \
		  line=${2:-} \
		  linecall=${3:-} \
		  cmd=${4:-} \
		  stack=${5:-}

	if (( err != 0 )); then
		log "ERROR: line ${line} - command '${cmd}' exited with status: ${err}."
		log "ERROR: In ${stack} called at line ${linecall}."
		log "DEBUG: From function ${stack[0]} (line ${linecall})."
	fi

	remove_temp
	gc sync

	(( errors > 0 )) && log "total number of non-zero returns: ${errors}"
	exit ${errors}
}

gc() {
	# guard command interactive
	local -r invocation=$*
	log "invoking ${invocation}"
	if ! command "$@"; then
		log "command ${invocation} failed."
		return 1
	fi
}

gci() { gc "$@" || input_dispatch "$* failed, proceed?"; }
gce() { gc "$@" || die 1 "$* failed."; }

require_command() {
	local -r cmd=${1}
	log "checking if ${cmd} is available"
	if ! hash "${cmd}" &>/dev/null; then
		log "could not find ${cmd}"
		return 1
	fi
}

ensure_commands() {
	for cmd in "$@"; do
		if ! require_command "${cmd}"; then
			log "${cmd} is essential, aborting"
			die 1
		fi
	done
}

verify_path_exists() {
	local -r path=${1}
	log "verifying if path ${path} exists"
	if [[ ! -d ${path} ]]; then
		log "path ${path} does not exist"
		return 1
	fi
}

verify_file_exists() {
	local -r file=${1}
	log "verifying if file ${file} exists"
	if [[ ! -f ${file} ]]; then
		log "file ${file} does not exist"
		return 1
	fi
}

verify_path_writable() {
	local -r path=${1}
	log "verifying if path ${path} is writable"
	if [[ ! -w ${path} ]]; then
		log "path ${path} is not writable"
		return 1
	fi
}

verify_data_written() {
	local -r src=${1} dst=${2}
	log "verifying file integrity of ${dst}"
	if ! cmp "${src}" "${dst}"; then
		log "there was an error validating ${dst}"
		return 1
	fi
}

input_dispatch() {
	if (( NON_INTERACTIVE > 0)); then
		(( errors++ ))
		log '!! (error) non-interactive, suppressing prompt'
		(( ERROR_ABORT > 0 )) && return 1
		return 0
	fi
	while read -r -p "${1} " yn; do
		case $yn in
			[Yy]* ) (( errors++ )); break;;
			[Nn]* ) die 1;;
			* ) printf 'Please answer yes or no.\n';;
		esac
	done
}

# short wrappers with input dispatch
vped() { verify_path_exists "${1}" || input_dispatch "Path ${1} does not exist, continue?"; }
vfed() { verify_file_exists "${1}" || input_dispatch "File ${1} does not exist, continue?"; }

vpwd() { verify_path_writable "${1}" || input_dispatch "Path ${1} is not writable, continue?"; }
vdwd() { verify_data_written "${1}" "${2}" || input_dispatch "There was an error validating ${2}, continue?"; }

check_targets() {
	ensure_commands gpg find "${COMPRESSOR_CMD[0]}"
	declare -g USE_RSYNC=1 USE_SCP=1 USE_RCLONE=1

	(( ${#BLK_LOCAL_TARGETS[@]} > 0 )) || die 1 'no block target configured'

	if ! require_command rsync; then
		# rsync was at least implicitly requested but not found
		if (( ${#RSYNC_REMOTE_TARGETS[@]} > 0 )); then
			if require_command ssh; then
				# try to gracefully fall back to SCP
				log 'rsync remote paths specified but no rsync binary found, falling back to scp'
				SCP_REMOTE_TARGETS+=("${RSYNC_REMOTE_TARGETS[@]}")
			else
				input_dispatch 'rsync remote paths specified but no ssh binary found, continue anyway?'
			fi
		fi
		log 'skipping all rsync operations'
		USE_RSYNC=0
	fi

	if ! require_command scp; then
		if (( ${#SCP_REMOTE_TARGETS[@]} > 0 )); then
			input_dispatch 'scp remote paths exist but no scp binary found, continue anyway?'
		fi
		log 'skipping all scp operations'
		USE_SCP=0
	fi

	if ! require_command rclone; then
		if (( ${#RCLONE_REMOTE_TARGETS[@]} > 0)); then
			input_dispatch 'rclone remote paths exist but no rclone binary found, continue anyway?'
		fi
		log 'skipping all rclone operations'
		USE_RCLONE=0
	fi

	declare -g USE_PAR=1
	if (( DATA_REDUNDANCY > 0 )) && ! require_command par2create; then
		input_dispatch 'par2create not found, skip recovery data creating?'
		log 'skipping the creation of par2 recovery files due to missing par2 binary'
		USE_PAR=0
	fi
}

safe_copy_file() {
	local -r src=${1} dst=${2}
	log "copying ${src} to ${dst}"
	vfed "${src}" \
		&& vped "${dst}" \
		&& vpwd "${dst}" \
		&& gci cp "${src}" "${dst}" \
		&& vdwd "${src}" "${dst}/$(basename "${src}")"
}

safe_shallow_copy_dir() {
	local -r src=${1} dst=${2}
	if (( USE_RSYNC > 0 )); then
		vpwd "${dst}" \
			&& gci rsync -qat "${WORKING_DIR}" "${dst}" \
			&& gci rsync -qact "${WORKING_DIR}" "${dst}"
	else
		log 'invoking cp'
		vpwd "${dst}" \
			&& gci mkdir -p "${dst}/${SCRIPT_EPOCH}"
		for f in "${src}/"*; do
			safe_copy_file "${f}" "${dst}/${SCRIPT_EPOCH}"
		done
	fi
}

create_recovery_data() {
	pushd .
	log "creating recovery information with ${DATA_REDUNDANCY}% redundancy"
	command cd "${WORKING_DIR}" \
		&& gci par2create -q -q -r"${DATA_REDUNDANCY}" "${ARCHIVE_SOURCE_PATH}"
	popd || die 1 "popd failed in create_recovery_data"
}

append_basename_element() {
	# contract: $1: out value nameref new array, $2: input array
	(( $# < 2 )) && die 1 "${FUNCNAME[1]} function contract violated"
	local -ar array=("${@:2}")
	local -n newarr=${1}
	for i in "${array[@]}"; do
		newarr+=('-C' "${i}" "$(basename "${i}")" )
	done
}

compile_exclude_file() {
	printf -v var "%s, " "${EXCLUDE_LIST[@]}"
	var=${var%??}
	log "compiling tar exclude file with: ${var}"
	printf -v var "%s\n" "${EXCLUDE_LIST[@]}";
	printf "%s" "${var%?}" > "${MYTMP}/excludes.list"
}

create_archive_folder() {
	(( ${#SOURCE_PATHS[@]} > 0 )) || die 1 'no SOURCE_PATHS defined '
	for src_path in "${SOURCE_PATHS[@]}"; do
		log "this is source: ${src_path}"
		if ! verify_path_exists "${src_path}"; then
			log "${src_path} is essential for operation, aborting."
			die 1 "invalid path ${src_path}"
		fi
	done

	gce mkdir -p "${WORKING_DIR}"
	compile_exclude_file

	# workaround until better logging exists
	log "invoking tar --exclude-from=${MYTMP}/excludes.list --exclude-caches -cf - ${SOURCE_PATHS[*]} | ${COMPRESSOR_CMD[*]} > ${MYTMP}/${ARCHIVE_NAME}"

	{ command tar --exclude-from="${MYTMP}/excludes.list" --exclude-caches -cf - "${SOURCE_PATHS[@]}" 2>/dev/null \
		| "${COMPRESSOR_CMD[@]}" > "${MYTMP}/${ARCHIVE_NAME}"; } 2>&1 | command tee -a "${LOG_ABS}"

	local -r gpg_opts=( --s2k-cipher-algo "${GPG_CIPHER}" --s2k-digest-algo "${GPG_DIGEST}" --s2k-mode "${GPG_MANGLE_MODE}" --s2k-count "${GPG_MANGLE_ITERATIONS}" )

	local -r tar_pipe_status=$?
	gce gpg -q --symmetric --compress-algo none "${gpg_opts[@]}" --output "${ARCHIVE_SOURCE_PATH}" "${MYTMP}/${ARCHIVE_NAME}" 2>&1 \
		| command tee -a "${LOG_ABS}"
	local -r gpg_pipe_status=$?

	if (( tar_pipe_status != 0 )); then
		log "tar or compressor error: ${tar_pipe_status}"
		die ${tar_pipe_status}
	fi
	if (( gpg_pipe_status != 0 )); then
		log "gpg error: ${gpg_pipe_status}"
		die ${gpg_pipe_status}
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
	local -r dst=${1}
	log 'copying archive folder'
	sleep 5s
	safe_shallow_copy_dir "${WORKING_DIR}" "${dst}"
}

scp_copy_callback() {
	local -r dst=${1}
	log "initiating archive folder remote copy to ${dst}"
	gci scp -qr "${WORKING_DIR}" "${dst}"
}

rsync_copy_callback() {
	local -r dst=${1}
	log "using rsync over ssh for remote copying ${dst}"
	gci rsync -qzact -e ssh "${WORKING_DIR}" "${dst}"
}

rclone_copy_callback() {
	local -r dst=${1}
	log "using rclone for copying ${dst}"
	gci rclone -q copy "${WORKING_DIR}" "${dst}/${SCRIPT_EPOCH}"
	log "verifying copied files for ${dst}"
	gci rclone -q check --one-way "${WORKING_DIR}" "${dst}/${SCRIPT_EPOCH}"
}

archive_cleanup_callback() {
	local -r dst=${1} age=${2}
	if [[ -d ${dst} ]]; then
		log "cleaning up old archives at ${dst}"
		command find "${dst}" -mindepth 1 -maxdepth 1 -type d -mtime +"${age}" -regextype posix-extended -regex "^${dst}/[0-9]{10}$" -print0 \
			| while IFS= read -r -d '' dir; do
			log "removing directory ${dir} and all of its content"
			command rm -rf "${dir}"
		done 2>/dev/null
	else
		log "invalid cleanup callback call, ${dst} is not a directory"
	fi
}

apply_do_path() {
	# $1 -> target paths array name (ref)
	# $2 -> function pointer (ref)
	# $@:3 -> forward arguments
	local -n target_paths=${2}
	local -r delegate=${1}
	for path in "${target_paths[@]}"; do
		log "processing ${path}"
		# shellcheck disable=SC2155
		local arg=$([[ -n ${*:3} ]] && printf " with argument(s) '%s'" "${*:3}")
		log "applying function ${delegate}${arg}"
		unset arg
		${delegate} "${path}" "${@:3}"
	done
}

apply_do_path_parallel() {
	# $1 -> number of concurrent processes
	# $2 -> target paths array name (ref)
	# $3 -> function pointer (ref)
	# $@:4 -> forward arguments
	local -i num_procs=${1}
	local -r delegate=${2}
	local -n target_paths=${3}
	local -r fifo=$(mktemp -u)
	mkfifo "${fifo}"
	exec 3<>"${fifo}"
	rm -f "${fifo}"

	for ((i=0; i<num_procs; ++i)); do
		echo 'p' >&3
	done

	for path in "${target_paths[@]}"; do
		read -r _ <&3
		(
			trap 'echo p >&3' EXIT
			log "parallel processing ${path}"
			# shellcheck disable=SC2155
			local arg=$([[ -n ${*:4} ]] && printf " with argument(s) '%s'" "${*:4}")
			log "applying function ${delegate}${arg}"
			unset arg
			${delegate} "${path}" "${@:4}"
		) &
	done
	wait
	exec 3>&-
}


process_targets() {
	# $1 -> target paths array name (ref)
	apply_do_path blk_copy_callback BLK_LOCAL_TARGETS
	if (( USE_RSYNC > 0 )); then
		apply_do_path rsync_copy_callback RSYNC_REMOTE_TARGETS
	fi
	if (( USE_SCP > 0 )); then
		apply_do_path scp_copy_callback SCP_REMOTE_TARGETS
	fi
	if (( USE_RCLONE > 0 )); then
		apply_do_path_parallel "${RCLONE_TASKS}" rclone_copy_callback RCLONE_REMOTE_TARGETS
	fi
	if (( ARCHIVE_CLEANUP > 0 )); then
		apply_do_path archive_cleanup_callback BLK_LOCAL_TARGETS "${KEEP_DAYS}"
	fi
}

# stop here if we got sourced
(return 0 2>/dev/null) && return

if [[ -n ${DEBUG:-} ]]; then
	trap 'cleanup "${?}" "${LINENO}" "${BASH_LINENO}" "${BASH_COMMAND}" $(printf "::%s" ${FUNCNAME[@]:-})' EXIT
else
	trap 'cleanup 0' EXIT
fi

init_logger
create_temp
check_targets
create_archive_folder
process_targets
