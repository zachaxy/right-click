use crate::files;
use anyhow::{Context, Result, bail, ensure};
use image::{DynamicImage, ImageFormat};
use serde_json::{Value, json};
use std::{
    fs::{self, File, OpenOptions},
    io::{Cursor, Read},
    path::{Path, PathBuf},
    process::Command,
};
pub fn convert(paths: &[PathBuf], dir: &Path, format: &str) -> Result<Value> {
    files::validate_sources(paths)?;
    let dir = files::directory(dir)?;
    let mut result = vec![];
    for p in paths {
        let stem = p.file_stem().unwrap_or_default().to_string_lossy();
        let ext = match format {
            "mac_icons" => "iconset",
            "ios_icons" => "appiconset",
            f => f,
        };
        let out = files::unique(&dir, &format!("{stem}.{ext}"))?;
        let tempdir = dir.join(format!(".rustclick-{}", files::id()));
        fs::create_dir(&tempdir)?;
        let temp = tempdir.join(format!("result.{ext}"));
        let r = (|| -> Result<()> {
            if format == "heic" {
                files::run(
                    Command::new("/usr/bin/sips")
                        .args(["-s", "format", "heic"])
                        .arg(p)
                        .arg("--out")
                        .arg(&temp),
                )?;
            } else {
                let img = match image::open(p) {
                    Ok(i) => i,
                    Err(_) => {
                        let decode = tempdir.join("decode.png");
                        files::run(
                            Command::new("/usr/bin/sips")
                                .args(["-s", "format", "png"])
                                .arg(p)
                                .arg("--out")
                                .arg(&decode),
                        )?;
                        image::open(decode)?
                    }
                };
                match format {
                    "png" | "webp" | "jpg" => {
                        let (im, f) = match format {
                            "jpg" => (DynamicImage::ImageRgb8(img.to_rgb8()), ImageFormat::Jpeg),
                            "webp" => (img, ImageFormat::WebP),
                            _ => (img, ImageFormat::Png),
                        };
                        im.save_with_format(&temp, f)?;
                    }
                    "icns" | "mac_icons" => {
                        let set = if format == "mac_icons" {
                            temp.clone()
                        } else {
                            tempdir.join("source.iconset")
                        };
                        fs::create_dir(&set)?;
                        for size in [16, 32, 128, 256, 512] {
                            for scale in [1, 2] {
                                let n = size * scale;
                                let suffix = if scale == 2 { "@2x" } else { "" };
                                img.resize_exact(n, n, image::imageops::FilterType::Lanczos3)
                                    .save(set.join(format!("icon_{size}x{size}{suffix}.png")))?;
                            }
                        }
                        if format == "icns" {
                            files::run(
                                Command::new("/usr/bin/iconutil")
                                    .arg("-c")
                                    .arg("icns")
                                    .arg(&set)
                                    .arg("-o")
                                    .arg(&temp),
                            )?;
                        }
                    }
                    "ios_icons" => {
                        fs::create_dir(&temp)?;
                        let mut entries = vec![];
                        for (idiom, sizes, scales) in [
                            ("iphone", vec![20., 29., 40., 60.], vec![2, 3]),
                            ("ipad", vec![20., 29., 40., 76., 83.5], vec![1, 2]),
                        ] {
                            for size in sizes {
                                for &scale in &scales {
                                    if size == 83.5 && scale == 1 {
                                        continue;
                                    }
                                    let px = (size * scale as f32) as u32;
                                    let name = format!("{idiom}-{size}-{scale}.png");
                                    DynamicImage::ImageRgb8(
                                        img.resize_exact(
                                            px,
                                            px,
                                            image::imageops::FilterType::Lanczos3,
                                        )
                                        .to_rgb8(),
                                    )
                                    .save(temp.join(&name))?;
                                    entries.push(json!({"idiom":idiom,"size":format!("{size}x{size}"),"scale":format!("{scale}x"),"filename":name}));
                                }
                            }
                        }
                        DynamicImage::ImageRgb8(
                            img.resize_exact(1024, 1024, image::imageops::FilterType::Lanczos3)
                                .to_rgb8(),
                        )
                        .save(temp.join("marketing.png"))?;
                        entries.push(json!({"idiom":"ios-marketing","size":"1024x1024","scale":"1x","filename":"marketing.png"}));
                        fs::write(
                            temp.join("Contents.json"),
                            serde_json::to_vec_pretty(
                                &json!({"images":entries,"info":{"version":1,"author":"RightClick"}}),
                            )?,
                        )?
                    }
                    _ => bail!("不支持的图片格式"),
                }
            }
            files::rename_exclusive(&temp, &out)?;
            Ok(())
        })();
        let _ = fs::remove_dir_all(tempdir);
        r?;
        result.push(out);
    }
    Ok(json!({"paths":result}))
}
pub fn qr(text: &str, dir: &Path) -> Result<Value> {
    ensure!(!text.is_empty(), "请输入二维码内容");
    let out = files::unique(&files::directory(dir)?, "二维码.png")?;
    let code = qrcode::QrCode::new(text.as_bytes())?;
    let image = code
        .render::<image::Luma<u8>>()
        .min_dimensions(320, 320)
        .build();
    let mut data = Cursor::new(Vec::new());
    image.write_to(&mut data, ImageFormat::Png)?;
    files::write_new(&out, &data.into_inner())?;
    Ok(json!({"paths":[out]}))
}
fn zip_tree(z: &mut zip::ZipWriter<File>, p: &Path, base: &Path) -> Result<()> {
    let m = fs::symlink_metadata(p)?;
    let name = p.strip_prefix(base)?.to_string_lossy().replace('\\', "/");
    let opts = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    ensure!(!m.is_symlink(), "压缩选择包含符号链接，请先选择实际文件");
    if m.is_dir() {
        z.add_directory(format!("{name}/"), opts)?;
        for e in fs::read_dir(p)? {
            zip_tree(z, &e?.path(), base)?
        }
    } else {
        z.start_file(name, opts)?;
        std::io::copy(&mut File::open(p)?, z)?;
    }
    Ok(())
}
pub fn compress(paths: &[PathBuf], dir: &Path, format: &str) -> Result<Value> {
    ensure!(format == "zip", "支持 ZIP 压缩；7z 使用独立归档适配器");
    files::validate_sources(paths)?;
    let dir = files::directory(dir)?;
    let out = files::unique(&dir, "归档.zip")?;
    let temp = dir.join(format!(".rustclick-{}.zip", files::id()));
    let r = (|| -> Result<()> {
        let f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        let mut z = zip::ZipWriter::new(f);
        let mut names = std::collections::HashSet::new();
        for p in paths {
            ensure!(
                names.insert(p.file_name()),
                "选择中存在同名文件，请分开压缩"
            );
            ensure!(!dir.starts_with(p), "请将归档保存在被压缩目录外");
            zip_tree(&mut z, p, p.parent().unwrap())?;
        }
        z.finish()?.sync_all()?;
        files::rename_exclusive(&temp, &out)?;
        Ok(())
    })();
    if r.is_err() {
        let _ = fs::remove_file(temp);
    }
    r?;
    Ok(json!({"paths":[out]}))
}
pub fn extract(paths: &[PathBuf], dir: &Path) -> Result<Value> {
    let dir = files::directory(dir)?;
    let mut result = vec![];
    for p in paths {
        let mut z = zip::ZipArchive::new(File::open(p)?)?;
        ensure!(z.len() <= 100_000, "归档条目过多");
        let mut size = 0u64;
        let mut names = std::collections::HashSet::new();
        for i in 0..z.len() {
            let f = z.by_index(i)?;
            let path = f.enclosed_name().context("拒绝包含越界路径的压缩包")?;
            ensure!(names.insert(path), "归档包含重复路径");
            ensure!(
                f.unix_mode().unwrap_or_default() & 0o170000 != 0o120000,
                "归档包含符号链接，已停止解压"
            );
            size = size.checked_add(f.size()).context("归档大小溢出")?;
            ensure!(
                size < 20 * 1024 * 1024 * 1024,
                "解压后超过 20 GB，请使用专用归档工具"
            );
        }
        let out = files::unique(&dir, &p.file_stem().unwrap_or_default().to_string_lossy())?;
        let tmp = dir.join(format!(".rustclick-{}", files::id()));
        fs::create_dir(&tmp)?;
        let r = (|| -> Result<()> {
            for i in 0..z.len() {
                let mut f = z.by_index(i)?;
                let target = tmp.join(f.enclosed_name().context("无效归档路径")?);
                if f.is_dir() {
                    fs::create_dir_all(&target)?
                } else {
                    fs::create_dir_all(target.parent().unwrap())?;
                    let mut output = OpenOptions::new()
                        .create_new(true)
                        .write(true)
                        .open(&target)?;
                    let expected = f.size();
                    let actual = std::io::copy(&mut (&mut f).take(expected + 1), &mut output)?;
                    ensure!(actual == expected, "归档条目长度异常");
                }
            }
            files::rename_exclusive(&tmp, &out)?;
            Ok(())
        })();
        if r.is_err() {
            let _ = fs::remove_dir_all(&tmp);
        }
        r?;
        result.push(out);
    }
    Ok(json!({"paths":result}))
}
