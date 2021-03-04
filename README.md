### Description

This is a simple bash 4.1+ script for archiving given folders to untrusted and/or unreliable locations. Folders provided are compressed and symmetrically AES encrypted.

A predefined amount of redundant information is added as separate files to ensure recoverability in case of bitrot or transmission errors. Archives are simply distinguished by placing them inside a unix timestamp labeled target directory.
The script contains a more than usual amount of error detection and handling to keep your data as safe as possible.
Log files are created in the working directory.

This script was initially designed to backup master password databases and security critical files, including GnuPG private keys, SSL certificates, crypto currency wallets et cetera.

**Always do a test run with noncritical data at first.**

#### Utilities required

gpg tar xz find

#### Optional (dependent on features used)

ssh par2 rsync rclone scp

The configuration file is a shell script sourced from `$XDG_CONFIG_HOME/backup/bfrg/config` by default.

#### Example configuration

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

#### Complete list of options (=default)

```bash
BLK_LOCAL_TARGETS=()        # block targets (HD, SSD, ..)
SCP_REMOTE_TARGETS=()       # scp remote targets
RSYNC_REMOTE_TARGETS=()     # rsync remote targets - uses ssh for transport, public key authentication strongly recommended
RCLONE_REMOTE_TARGETS=()    # rclone targets - must be configured inside rclone already

ARCHIVE_NAME=archive_${SCRIPT_EPOCH}.tar.xz
LOG_FILE=bfrg_${SCRIPT_EPOCH}.log}

ARCHIVE_CLEANUP=1           # cleanup old archived on block targets (only works with BLK)
KEEP_DAYS=365               # days to keep archives - also ensures that one last archive is available at all times
SELF_REPLICATE=1            # copy bfrg.sh to the target
SAFE_DELETE=1               # use *shred* before deleting temporary files, recommended if SAFE_TMP is on a harddisk
DATA_REDUNDANCY=5           # add 5% recovery data
VERBOSE=1                   # be verbose by default
NON_INTERACTIVE=0           # prompt user by default if the script encounters an error
ERROR_ABORT=0               # stop processing any further targets if encountering an error in non-interactive mode
SAFE_TMP=/tmp               # directory used for creating the archive, recommended to be on a secure or volatile device

COMPRESSOR_CMD=xz           # default compressor; the restore script supposes availability of -d for decompression
COMPRESSOR_OPT=-q -9e --threads=0 -v

EXCLUDE_LIST=( 'System Volume Information' '*~' '#*#' '.#*' 'tmp' '.tmp' '.nv' 'GPUCache' '.ccache' '.cache' '.var' )
```

For cloud target locations (Google Drive, Amazon S3, OneDrive etc.), [**rclone**](https://github.com/rclone/rclone), with the desired services already configured, is a prerequisite. For adding optional redundant information (enabled by default), [**par2cmdline**](https://github.com/Parchive/par2cmdline), available in the default repositories of Debian, Fedora and Arch Linux and most other distributions, is used.  

The [recovery script](https://github.com/zenofile/bfrg/blob/master/restore.sh) takes an encrypted archive as argument and tries to repair it if necessary, as far as redundant information is present, before unpacking it into the current working directory.
