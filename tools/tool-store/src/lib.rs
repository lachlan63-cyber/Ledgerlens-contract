//! Shared persistence primitives for off-chain tools (issue #1397).
//!
//! Deliberately tiny: only the pieces that were duplicated verbatim across
//! `tools/recovery`, `tools/score-submitter` and friends. It is *not* a
//! datastore abstraction; see `docs/SPIKE_TOOL_STORAGE_EVALUATION.md`.

use std::fs::{self, OpenOptions};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use sha2::{Digest, Sha256};

/// Lowercase hex SHA-256 of `bytes`.
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

/// `<path>.bak`: where the previous version is parked during a replace.
pub fn backup_path(path: &Path) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(".bak");
    PathBuf::from(value)
}

/// The file to read for `path`: `path` itself, or its `.bak` if a crash left
/// only the backup behind.
pub fn readable_path(path: &Path) -> PathBuf {
    if path.exists() {
        path.to_path_buf()
    } else {
        backup_path(path)
    }
}

/// Write `bytes` to `path` crash-safely: write + fsync a `.tmp`, park the old
/// file as `.bak`, rename into place, restore the backup if the rename fails.
pub fn write_bytes_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let mut temporary = path.as_os_str().to_os_string();
    temporary.push(".tmp");
    let temporary = PathBuf::from(temporary);
    let backup = backup_path(path);
    fs::write(&temporary, bytes).with_context(|| format!("writing {}", temporary.display()))?;
    OpenOptions::new()
        .write(true)
        .open(&temporary)
        .with_context(|| format!("opening {} for sync", temporary.display()))?
        .sync_all()
        .with_context(|| format!("syncing {}", temporary.display()))?;
    if path.exists() {
        if backup.exists() {
            fs::remove_file(&backup).with_context(|| format!("removing {}", backup.display()))?;
        }
        fs::rename(path, &backup)
            .with_context(|| format!("preserving previous file {}", path.display()))?;
    }
    if let Err(error) = fs::rename(&temporary, path) {
        if backup.exists() {
            let _ = fs::rename(&backup, path);
        }
        let _ = fs::remove_file(&temporary);
        return Err(error).with_context(|| format!("replacing {}", path.display()));
    }
    if backup.exists() {
        fs::remove_file(&backup).with_context(|| format!("removing {}", backup.display()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tool-store-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn sha256_known_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn atomic_write_replaces_and_cleans_up() {
        let dir = scratch("atomic");
        let path = dir.join("nested/state.json");
        write_bytes_atomic(&path, b"one").unwrap();
        write_bytes_atomic(&path, b"two").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"two");
        assert!(!backup_path(&path).exists());
        assert!(!path.with_extension("json.tmp").exists());
    }

    #[test]
    fn readable_path_falls_back_to_backup() {
        let dir = scratch("readable");
        let path = dir.join("cp.json");
        fs::write(backup_path(&path), b"old").unwrap();
        assert_eq!(readable_path(&path), backup_path(&path));
        fs::write(&path, b"new").unwrap();
        assert_eq!(readable_path(&path), path);
    }
}
