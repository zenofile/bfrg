#!/usr/bin/env bash
# vim: ft=bash ts=4 sw=4 sts=-1 noet

set -o nounset
set -o pipefail
set -o errexit

shopt -s lastpipe

[[ ${TRACE:-} ]] && set -o xtrace

# shellcheck disable=SC1090
source "$(dirname "${BASH_SOURCE[0]}")/bfrg.sh"
# shellcheck disable=SC2034
LOG_FILE=restore-${SCRIPT_EPOCH}.log

verify_repair() {
	local -r infile=${1}
	require_command par2 || return 0
	log 'attempting file verification'
	command par2 repair -- "$infile"
}

decrypt_stdout() {
	local -r infile=${1}
	local -r ts=${infile%%.*}
	
	mkdir -p "${ts}"
	trap 'rmdir --ignore-fail-on-non-empty ${ts}' ERR SIGINT

	log 'attempting file decryption and unpacking'
	# assume the compressor supports -d for decompression
	command gpg --decrypt -- "${infile}" | command "${COMPRESSOR_CMD[0]}" -d -- | command tar -C "${ts}" -xv --
}

(($# < 1)) && die "no input file specified"
readonly INFILE=${1}

init_logger

if ! verify_file_exists "${INFILE}"; then
	die "cannot read file ${INFILE}"
fi

ensure_commands gpg tar "${COMPRESSOR_CMD[0]}"
verify_repair "${INFILE}"
decrypt_stdout "${INFILE}"
