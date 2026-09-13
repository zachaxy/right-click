use crate::files;
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Component, Path, PathBuf},
    process::{Command, Stdio},
};
fn binary() -> Result<PathBuf> {
    let exe = std::env::current_exe()?;
    let mut options = vec![exe.parent().unwrap().join("../Resources/bin/7zz")];
    if let Some(p) = std::env::var_os("RUSTCLICK_7ZZ") {
        options.insert(0, p.into())
    }
    options.push(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("build/sevenzip/sevenzip/26.03/bin/7zz"),
    );
    options.push(PathBuf::from("/opt/homebrew/bin/7zz"));
    options
        .into_iter()
        .find(|p| p.is_file())
        .context("7z 组件缺失，请重新运行打包脚本")
}
fn command() -> Result<Command> {
    let mut c = Command::new(binary()?);
    c.stdin(Stdio::null());
    Ok(c)
}
fn no_links(p: &Path) -> Result<()> {
    let m = fs::symlink_metadata(p)?;
    ensure!(!m.is_symlink(), "归档暂不接受符号链接，请选择实际文件");
    files::name(&p.file_name().unwrap_or_default().to_string_lossy())?;
    if m.is_dir() {
        for e in fs::read_dir(p)? {
            no_links(&e?.path())?
        }
    }
    Ok(())
}
pub fn compress(paths: &[PathBuf], dir: &Path, format: &str, password: &str) -> Result<Value> {
    ensure!(matches!(format, "zip" | "7z"), "无效归档格式");
    files::validate_sources(paths)?;
    let dir = files::directory(dir)?;
    let out = files::unique(&dir, &format!("归档.{format}"))?;
    for p in paths {
        no_links(p)?;
        ensure!(
            !dir.starts_with(fs::canonicalize(p)?),
            "请将归档保存在所选目录之外"
        );
    }
    let tmp = dir.join(format!(".rustclick-{}", files::id()));
    fs::create_dir(&tmp)?;
    let result = (|| -> Result<()> {
        let source = tmp.join("source");
        fs::create_dir(&source)?;
        for p in paths {
            let target = source.join(p.file_name().unwrap());
            ensure!(!files::exists(&target), "选择中存在同名文件，请分开压缩");
            files::copy_one(p, &target)?;
        }
        let archive = tmp.join(format!("result.{format}"));
        let mut c = command()?;
        c.current_dir(&source)
            .args(["a", "-y", "-bsp0", "-bso0"])
            .arg(format!("-t{format}"));
        if !password.is_empty() {
            c.arg(format!("-p{password}"));
            c.arg(if format == "7z" {
                "-mhe=on"
            } else {
                "-mem=AES256"
            });
        }
        c.arg("--").arg(&archive).arg(".");
        files::run(&mut c)?;
        files::rename_exclusive(&archive, &out)?;
        Ok(())
    })();
    let _ = fs::remove_dir_all(tmp);
    result?;
    Ok(json!({"paths":[out]}))
}
pub fn extract(paths: &[PathBuf], dir: &Path, password: &str) -> Result<Value> {
    files::validate_sources(paths)?;
    let dir = files::directory(dir)?;
    let mut done = vec![];
    for path in paths {
        let pass = format!("-p{}", if password.is_empty() { "-" } else { password });
        let listing = files::run(command()?.args(["l", "-slt", "-ba", &pass, "--"]).arg(path))?;
        let (mut total, mut count) = (0u64, 0usize);
        for line in listing.lines() {
            if let Some(p) = line.strip_prefix("Path = ") {
                let p = Path::new(p);
                ensure!(
                    !p.is_absolute()
                        && !p.as_os_str().is_empty()
                        && !p.to_string_lossy().contains(['\\', ':']),
                    "归档包含无效路径"
                );
                ensure!(
                    p.components()
                        .all(|c| matches!(c, Component::Normal(_) | Component::CurDir)),
                    "拒绝包含越界路径的归档"
                );
                count += 1;
                ensure!(count < 100_000, "归档条目过多");
            }
            if let Some(n) = line.strip_prefix("Size = ") {
                total = total
                    .checked_add(n.parse::<u64>()?)
                    .context("归档大小溢出")?;
                ensure!(total < 20 * 1024 * 1024 * 1024, "解压后超过 20 GB");
            }
            ensure!(
                !line.starts_with("Symbolic Link = ")
                    && !line.starts_with("Hard Link = ")
                    && !line.contains("Alternate Stream = +"),
                "拒绝包含链接或额外数据流的归档"
            );
            if let Some(a) = line.strip_prefix("Attributes = ") {
                ensure!(
                    !a.split_whitespace().any(|x| x.starts_with('l')),
                    "归档包含符号链接"
                );
            }
        }
        let out = files::unique(
            &dir,
            &path.file_stem().unwrap_or_default().to_string_lossy(),
        )?;
        let tmp = dir.join(format!(".rustclick-{}", files::id()));
        fs::create_dir(&tmp)?;
        let result = (|| -> Result<()> {
            files::run(
                command()?
                    .args(["x", "-y", "-bso0", "-bsp0", &pass])
                    .arg(format!("-o{}", tmp.display()))
                    .arg("--")
                    .arg(path),
            )?;
            no_links(&tmp)?;
            files::rename_exclusive(&tmp, &out)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_dir_all(tmp);
        }
        result?;
        done.push(out);
    }
    Ok(json!({"paths":done}))
}
