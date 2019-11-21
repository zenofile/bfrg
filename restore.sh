#!/usr/bin/env bash

set -o nounset
set -o pipefail
set -o errexit

[[ ${TRACE:-} ]] && set -o xtrace

source "$(dirname "${BASH_SOURCE[0]}")/bfrg.sh"
LOG_FILE="restore-${SCRIPT_EPOCH}.log"

_verify_repair() {
    local -r infile="$1"
    _require_command par2 || return 0
    _log "attempting file verification"
    command par2 repair -- "$infile"
}

_decrypt_stdout() {
    local -r infile="$1"
    _log "attempting file decryption and unpacking"
    command gpg --decrypt "$infile" | command xz -d | command tar -xv --
}

(($# < 1)) && _die "no input file specified" 
readonly INFILE="$1"

_init_logger

if ! _verify_file_exists "$INFILE"; then
    _die "cannot read file ${INFILE}"
fi

_ensure_commands gpg xz tar
_verify_repair "$INFILE"
_decrypt_stdout "$INFILE"
