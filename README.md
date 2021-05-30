## Description

This is a simple bash 4.2+ script for archiving given folders to untrusted and/or unreliable locations. Folders provided are compressed and symmetrically AES encrypted.

A predefined amount of redundant information is added as separate files to ensure recoverability in case of bitrot or transmission errors. Archives are simply distinguished by placing them inside a unix timestamp labeled target directory.
The script contains a more than usual amount of error detection and handling to keep your data as safe as possible.
Log files are created in the working directory.

This script was initially designed to backup master password databases and security critical files, including GnuPG private keys, SSL certificates, crypto currency wallets et cetera.

**Always do a test run with noncritical data at first.**

### Utilities required (using default compressor)

_gpg_ _tar_ _find_ _xz_

### Optional (depends on features used)

_ssh_ _par2_ _rsync_ _rclone_ _scp_

### COnfiguration

The configuration file is a shell script sourced from `$XDG_CONFIG_HOME/backup/bfrg/config` by default.

### List of options

| Option | Type | Default | Description |
|-|-|-|-|
| BLK_LOCAL_TARGETS | A | `( )` | Local block targets. |
| SCP_REMOTE_TARGETS | A | `( )` | _scp_ remote targets. |
| RSYNC_REMOTE_TARGETS | A | `( )` | _rsync_ remote targets. Uses ssh for transport. |
| RCLONE_REMOTE_TARGETS | A | `( )` | _rclone_ targets. Requires existing rclone configuration. |
| ARCHIVE_NAME | V | `archive_${SCRIPT_EPOCH}.tar.xz` | Output file. |
| LOG_FILE | V | `bfrg_${SCRIPT_EPOCH}.log` | Log file. |
| ARCHIVE_CLEANUP | V | `1` | Cleanup old archived on block targets (only works with BLK). |
| KEEP_DAYS | V | `365` | Days to keep archives. Ensures that one last archive is available at all times. |
| SELF_REPLICATE | V | `1` | Copy script to the target for later reference. |
| SAFE_DELETE | V | `1` | Use *shred* before deleting temporary files, recommended if SAFE_TMP is on a hard disk. |
| DATA_REDUNDANCY | V | `5` | Add n% recovery data. |
| VERBOSE | V | `1` | Be verbose. |
| NON_INTERACTIVE | V | `0` | Prompt user on error. |
| ERROR_ABORT | V | `0` | Stop processing targets on error in non-interactive mode. |
| SAFE_TMP | V | `/tmp` | Temporary directory. Volatile storage recommended.|
| COMPRESSOR_CMD | A | `( xz --q -9e --threads=0 -v )` | Compressor and its arguments being used for compression. |
| EXCLUDE_LIST | A | `( 'System Volume Information' ' *~' '#*#' '.#* ' 'tmp' '.tmp' '.nv' 'GPUCache' '.ccache' '.cache' '.var' )` | From archiving excluded directories. |
| GPG_CIPHER | V | `AES256` | Encryption cipher. |
| GPG_DIGEST | V | `SHA512` | Encryption digest. |
| GPG_MANGLE_MODE | V | `3` | Mangle mode. |
| GPG_MANGLE_ITERATIONS | V | `65011712` | Mangle iterations. |
  
### Notes

For cloud target locations (Google Drive, Amazon S3, OneDrive etc.), [**rclone**](https://github.com/rclone/rclone), with the desired services already configured, is a prerequisite. For adding optional redundant information (enabled by default), [**par2cmdline**](https://github.com/Parchive/par2cmdline), available in the default repositories of Debian, Fedora and Arch Linux and most other distributions, is used.  

The [recovery script](https://github.com/zenofile/bfrg/blob/master/restore.sh) takes an encrypted archive as argument and tries to repair it if necessary, as far as redundant information is present, before unpacking it into the current working directory.

### Example configuration

```bash
# secure temporary file location, volatile (tmpfs) or encrypted location should be preferred
SAFE_TMP=~/.tmp

# source folders to include in the archive
SOURCE_PATHS=( ~/mysecrets )

# block layer targets where the final archive is copied to
BLK_LOCAL_TARGETS=( ~/backup/secrets /media/data/backup /run/media/${USER}/FLASH_DRIVE )

# rsync targets, ssh is used for transport
RSYNC_REMOTE_TARGETS=( ${USER}@remote.example.org:/homes/${USER}/rsync_backup/secrets )

# rclone cloud targets, all rclone backends are supported
RCLONE_REMOTE_TARGETS=( 'Backblaze:rclonebak/secrets' 'OneDrive:_backup/secrets' 'GoogleDrive:_backup/secrets' 'Dropbox:_backup/secrets' )

# non-interactive mode, count and log errors but proceed without asking questions - useful for automation
NON_INTERACTIVE=1
```