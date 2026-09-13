use anyhow::{Context, Result, bail, ensure};
use md5::Md5;
use serde_json::{Value, json};
use sha1::Sha1;
use sha2::{Digest, Sha256, Sha512};
use std::{
    ffi::CString,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::{
        macos::fs::MetadataExt,
        unix::{ffi::OsStrExt, fs::PermissionsExt},
    },
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicU64, Ordering},
};
unsafe extern "C" {
    fn lchflags(path: *const libc::c_char, flags: u32) -> libc::c_int;
}
static SEQ: AtomicU64 = AtomicU64::new(0);
pub fn id() -> String {
    format!(
        "{}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    )
}
pub fn name(s: &str) -> Result<&str> {
    ensure!(
        !s.trim().is_empty()
            && s != "."
            && s != ".."
            && !s.contains(['/', ':', '\0', '\n', '\r'])
            && s.len() < 240,
        "文件名为空、过长或包含无效字符"
    );
    Ok(s)
}
pub fn directory(p: &Path) -> Result<PathBuf> {
    ensure!(p.is_absolute(), "请选择绝对路径");
    let p = fs::canonicalize(p).context("无法访问目录，请检查磁盘权限")?;
    ensure!(p.is_dir(), "目标不是文件夹");
    Ok(p)
}
pub fn exists(p: &Path) -> bool {
    fs::symlink_metadata(p).is_ok()
}
pub fn unique(dir: &Path, filename: &str) -> Result<PathBuf> {
    name(filename)?;
    let p = dir.join(filename);
    if !exists(&p) {
        return Ok(p);
    };
    let f = Path::new(filename);
    let stem = f.file_stem().unwrap_or_default().to_string_lossy();
    let ext = f
        .extension()
        .map(|x| format!(".{}", x.to_string_lossy()))
        .unwrap_or_default();
    for n in 2..100_000 {
        let p = dir.join(format!("{stem} {n}{ext}"));
        if !exists(&p) {
            return Ok(p);
        }
    }
    bail!("同名文件过多")
}
pub fn rename_exclusive(a: &Path, b: &Path) -> Result<()> {
    let a = CString::new(a.as_os_str().as_bytes())?;
    let b = CString::new(b.as_os_str().as_bytes())?;
    if unsafe { libc::renamex_np(a.as_ptr(), b.as_ptr(), libc::RENAME_EXCL) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}
pub fn write_new(p: &Path, data: &[u8]) -> Result<()> {
    let mut f = OpenOptions::new().write(true).create_new(true).open(p)?;
    f.write_all(data)?;
    f.sync_all()?;
    Ok(())
}
pub fn atomic_json(p: &Path, v: &Value) -> Result<()> {
    fs::create_dir_all(p.parent().unwrap())?;
    let tmp = p.with_extension(format!("{}.tmp", id()));
    write_new(&tmp, &serde_json::to_vec_pretty(v)?)?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
    fs::rename(tmp, p)?;
    Ok(())
}
pub fn run(c: &mut Command) -> Result<String> {
    let out = c.output()?;
    ensure!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    Ok(String::from_utf8_lossy(&out.stdout).trim().into())
}
pub fn validate_sources(paths: &[PathBuf]) -> Result<()> {
    ensure!(!paths.is_empty(), "请先选择文件");
    for (i, p) in paths.iter().enumerate() {
        ensure!(p.is_absolute() && exists(p), "文件不存在：{}", p.display());
        let parent = directory(p.parent().context("无效文件")?)?;
        let full = parent.join(p.file_name().context("不能操作磁盘根目录")?);
        for q in paths.iter().skip(i + 1) {
            let qp = directory(q.parent().context("无效路径")?)?
                .join(q.file_name().context("无效路径")?);
            ensure!(
                !qp.starts_with(&full) && !full.starts_with(&qp),
                "不能同时选择文件夹及其子项，或重复选择同一文件"
            );
        }
    }
    Ok(())
}
pub fn protected(p: &Path) -> Result<()> {
    let parent = directory(p.parent().context("不能操作根目录")?)?;
    let p = parent.join(p.file_name().context("不能操作根目录")?);
    let home = std::env::var("HOME").unwrap_or_default();
    ensure!(
        p.components().count() > 2
            && p != Path::new(&home)
            && !p.starts_with("/System")
            && !p.starts_with("/Library")
            && !p.starts_with("/usr")
            && !p.starts_with("/bin")
            && !p.starts_with("/sbin")
            && !p.starts_with("/private/etc")
            && !p.starts_with("/private/var/db"),
        "不能删除或移动受保护的系统目录"
    );
    Ok(())
}
pub fn copy_one(src: &Path, dest: &Path) -> Result<()> {
    let tmp = dest.parent().unwrap().join(format!(".rustclick-{}", id()));
    let result = (|| {
        run(Command::new("/usr/bin/ditto")
            .arg("--rsrc")
            .arg("--extattr")
            .arg(src)
            .arg(&tmp))?;
        rename_exclusive(&tmp, dest)
    })();
    if result.is_err() && exists(&tmp) {
        let _ = remove(&tmp);
    }
    result
}
pub fn transfer(paths: &[PathBuf], dir: &Path, moving: bool) -> Result<Value> {
    validate_sources(paths)?;
    let dir = directory(dir)?;
    for p in paths {
        if moving {
            protected(p)?;
        }
        if p.is_dir() && !p.is_symlink() {
            let src = fs::canonicalize(p)?;
            ensure!(!dir.starts_with(src), "目标不能位于源文件夹内部");
        }
    }
    let mut done = vec![];
    let mut errors = vec![];
    for p in paths {
        let target = unique(&dir, &p.file_name().unwrap().to_string_lossy())?;
        let result = if moving {
            match rename_exclusive(p, &target) {
                Ok(()) => Ok(()),
                Err(e)
                    if e.downcast_ref::<std::io::Error>()
                        .and_then(|e| e.raw_os_error())
                        == Some(libc::EXDEV) =>
                {
                    copy_one(p, &target).and_then(|_| remove(p))
                }
                Err(e) => Err(e),
            }
        } else {
            copy_one(p, &target)
        };
        match result {
            Ok(()) => done.push(json!({"source":p,"path":target})),
            Err(e) => errors.push(json!({"source":p,"error":e.to_string()})),
        }
    }
    Ok(
        json!({"paths":done.iter().map(|x|x["path"].clone()).collect::<Vec<_>>(),"completed":done,"errors":errors}),
    )
}
pub fn remove(p: &Path) -> Result<()> {
    if fs::symlink_metadata(p)?.is_dir() {
        fs::remove_dir_all(p)?
    } else {
        fs::remove_file(p)?
    }
    Ok(())
}
pub fn hidden(p: &Path, yes: bool) -> Result<()> {
    let flags = fs::symlink_metadata(p)?.st_flags();
    set_flags(
        p,
        if yes {
            flags | libc::UF_HIDDEN
        } else {
            flags & !libc::UF_HIDDEN
        },
    )
}
pub fn set_flags(p: &Path, flags: u32) -> Result<()> {
    let p = CString::new(p.as_os_str().as_bytes())?;
    ensure!(
        unsafe { lchflags(p.as_ptr(), flags) } == 0,
        "无法修改文件隐藏标志：{}",
        std::io::Error::last_os_error()
    );
    Ok(())
}
pub fn info(p: &Path) -> Result<Value> {
    let m = fs::symlink_metadata(p)?;
    let mut v = json!({"path":p,"name":p.file_name().unwrap_or_default().to_string_lossy(),"bytes":m.len(),"directory":m.is_dir(),"symlink":m.is_symlink(),"permissions":format!("{:o}",m.permissions().mode()&0o777),"hidden":m.st_flags()&libc::UF_HIDDEN!=0});
    if m.is_file() {
        let mut f = File::open(p)?;
        let (mut md5, mut sha1, mut sha256, mut sha512) =
            (Md5::new(), Sha1::new(), Sha256::new(), Sha512::new());
        let mut b = [0; 65536];
        loop {
            let n = f.read(&mut b)?;
            if n == 0 {
                break;
            }
            md5.update(&b[..n]);
            sha1.update(&b[..n]);
            sha256.update(&b[..n]);
            sha512.update(&b[..n]);
        }
        v["md5"] = json!(format!("{:x}", md5.finalize()));
        v["sha1"] = json!(format!("{:x}", sha1.finalize()));
        v["sha256"] = json!(format!("{:x}", sha256.finalize()));
        v["sha512"] = json!(format!("{:x}", sha512.finalize()));
    }
    Ok(v)
}
pub fn scan(dir: &Path) -> Result<Value> {
    let dir = directory(dir)?;
    let mut stack = vec![dir.clone()];
    let (mut count, mut bytes) = (0u64, 0u64);
    let mut largest = vec![];
    let mut errors = 0;
    while let Some(p) = stack.pop() {
        let entries = match fs::read_dir(&p) {
            Ok(x) => x,
            Err(_) => {
                errors += 1;
                continue;
            }
        };
        for entry in entries {
            let Ok(e) = entry else {
                errors += 1;
                continue;
            };
            let Ok(m) = fs::symlink_metadata(e.path()) else {
                errors += 1;
                continue;
            };
            if m.is_dir() {
                stack.push(e.path())
            } else if m.is_file() {
                count += 1;
                bytes += m.len();
                largest.push((m.len(), e.path()));
                if largest.len() > 200 {
                    largest.sort_by_key(|a| std::cmp::Reverse(a.0));
                    largest.truncate(50);
                }
            }
        }
    }
    largest.sort_by_key(|a| std::cmp::Reverse(a.0));
    largest.truncate(30);
    Ok(
        json!({"bytes":bytes,"files":count,"unreadable":errors,"largest":largest.into_iter().map(|(b,p)|json!({"path":p,"bytes":b})).collect::<Vec<_>>()}),
    )
}
