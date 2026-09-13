mod archive;
pub mod files;
mod media;
mod templates;
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    fs,
    os::{macos::fs::MetadataExt, unix::fs::PermissionsExt},
    path::{Path, PathBuf},
    sync::OnceLock,
};
pub type NativeFn = unsafe extern "C" fn(*const std::ffi::c_char) -> *mut std::ffi::c_char;
pub static NATIVE: OnceLock<NativeFn> = OnceLock::new();
pub fn native(v: Value) -> Result<Value> {
    let Some(f) = NATIVE.get() else {
        bail!("此功能需要在 RightClick 桌面应用中运行")
    };
    let text = std::ffi::CString::new(v.to_string())?;
    let p = unsafe { f(text.as_ptr()) };
    ensure!(!p.is_null(), "系统适配器未返回结果");
    let s = unsafe { std::ffi::CStr::from_ptr(p) }
        .to_string_lossy()
        .into_owned();
    unsafe { libc::free(p.cast()) };
    let v: Value = serde_json::from_str(&s)?;
    if let Some(e) = v["error"].as_str() {
        bail!("{e}")
    }
    Ok(v)
}
fn strv<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key].as_str().with_context(|| format!("缺少参数 {key}"))
}
fn paths(v: &Value) -> Result<Vec<PathBuf>> {
    let r = v["paths"]
        .as_array()
        .context("请先选择文件")?
        .iter()
        .map(|v| v.as_str().map(PathBuf::from).context("无效路径"))
        .collect::<Result<Vec<_>>>()?;
    files::validate_sources(&r)?;
    Ok(r)
}
fn out(p: PathBuf) -> Value {
    json!({"paths":[p]})
}
pub struct Engine {
    pub root: PathBuf,
}
impl Engine {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }
    fn config_path(&self) -> PathBuf {
        self.root.join("config.json")
    }
    fn read(&self, name: &str, default: Value) -> Result<Value> {
        let p = self.root.join(name);
        if !p.exists() {
            return Ok(default);
        }
        Ok(serde_json::from_slice(&fs::read(p)?)?)
    }
    fn defaults(&self) -> Value {
        let h = std::env::var("HOME").unwrap_or_default();
        json!({"showTray":true,"hideOnCut":false,"confirmDelete":true,"openAfterCreate":false,"sound":false,"externalDisks":true,"cloudShortcut":false,"terminalTab":true,"showIcons":true,"groupMenus":true,"disabled":[],"templates":[],"favorites":[{"name":"桌面","path":format!("{h}/Desktop")},{"name":"下载","path":format!("{h}/Downloads")},{"name":"文稿","path":format!("{h}/Documents")}],"apps":[{"name":"终端","id":"com.apple.Terminal"},{"name":"iTerm2","id":"com.googlecode.iterm2"},{"name":"VS Code","id":"com.microsoft.VSCode"},{"name":"Typora","id":"abnerworks.Typora"},{"name":"PyCharm","id":"com.jetbrains.pycharm.ce"},{"name":"IntelliJ IDEA","id":"com.jetbrains.intellij.ce"},{"name":"CLion","id":"com.jetbrains.CLion"},{"name":"Android Studio","id":"com.google.android.studio"},{"name":"Obsidian","id":"md.obsidian"}],"menuLevels":{},"menuGroupLevels":{},"menuOrder":["create","cut","paste","copy","move","favorites","open_app","info","convert","compress","extract","icons","tools"]})
    }
    fn config(&self) -> Result<Value> {
        self.read("config.json", self.defaults())
    }
    fn save_config(&self, v: &Value) -> Result<()> {
        ensure!(v.is_object(), "配置格式错误");
        for k in ["templates", "favorites", "apps", "disabled", "menuOrder"] {
            ensure!(v[k].is_array(), "无效配置项：{k}");
        }
        if let Some(levels) = v.get("menuLevels") {
            let levels = levels.as_object().context("菜单层级配置必须是对象")?;
            for level in levels.values() {
                ensure!(
                    level.as_u64().is_some_and(|n| (1..=3).contains(&n)),
                    "菜单层级只能是一级、二级或三级"
                );
            }
        }
        if let Some(levels) = v.get("menuGroupLevels") {
            let levels = levels.as_object().context("菜单分组位置必须是对象")?;
            for level in levels.values() {
                ensure!(
                    level.as_u64().is_some_and(|n| (1..=2).contains(&n)),
                    "菜单分组只能放在一级或二级，子项默认跟随分组"
                );
            }
        }
        files::atomic_json(&self.config_path(), v)
    }
    fn cut_items(&self) -> Result<Value> {
        self.read("cut.json", json!([]))
    }
    fn cancel_cut(&self) -> Result<()> {
        let items = self.cut_items()?;
        for i in items.as_array().context("剪切状态损坏")? {
            let p = Path::new(strv(i, "path")?);
            if files::exists(p) {
                let m = fs::symlink_metadata(p)?;
                if m.st_ino() == i["inode"].as_u64().unwrap_or(0)
                    && m.st_dev() as u64 == i["device"].as_u64().unwrap_or(0)
                {
                    files::set_flags(p, i["flags"].as_u64().unwrap_or(0) as u32)?
                }
            }
        }
        files::atomic_json(&self.root.join("cut.json"), &json!([]))
    }
    pub fn execute(&mut self, v: Value) -> Result<Value> {
        let cmd = strv(&v, "cmd")?;
        match cmd {
            "state" => Ok(
                json!({"license":"free","version":env!("CARGO_PKG_VERSION"),"home":std::env::var("HOME").unwrap_or_default(),"config":self.config()?,"formats":templates::formats(),"cut":self.cut_items()?,"configPath":self.config_path()}),
            ),
            "save_config" => {
                self.save_config(&v["config"])?;
                Ok(json!({"saved":true}))
            }
            "create" => {
                let dir = files::directory(Path::new(strv(&v, "dir")?))?;
                let name = files::name(v["name"].as_str().unwrap_or("未命名"))?;
                let config = self.config()?;
                if let Some(id) = v["template"].as_str() {
                    let t = config["templates"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .find(|t| t["id"] == id)
                        .context("模板不存在")?;
                    let src = Path::new(strv(t, "path")?);
                    let ext = src.extension().unwrap_or_default().to_string_lossy();
                    let filename = if Path::new(name).extension().is_some() {
                        name.into()
                    } else {
                        format!("{name}.{ext}")
                    };
                    let p = files::unique(&dir, &filename)?;
                    files::copy_one(src, &p)?;
                    return Ok(out(p));
                }
                let format = v["format"].as_str().unwrap_or("txt");
                let filename = if Path::new(name).extension().is_some() {
                    name.into()
                } else {
                    format!("{name}.{format}")
                };
                let p = files::unique(&dir, &filename)?;
                templates::create(&p, format)?;
                Ok(out(p))
            }
            "template_add" => {
                let src = Path::new(strv(&v, "path")?);
                ensure!(files::exists(src), "模板文件不存在");
                let id = files::id();
                let folder = self.root.join("templates").join(&id);
                fs::create_dir_all(&folder)?;
                let p = folder.join(src.file_name().context("无效模板")?);
                files::copy_one(src, &p)?;
                let mut config = self.config()?;
                let t = json!({"id":id,"name":v["name"].as_str().unwrap_or("自定义模板"),"path":p,"ext":src.extension().unwrap_or_default().to_string_lossy(),"enabled":true});
                config["templates"].as_array_mut().unwrap().push(t.clone());
                self.save_config(&config)?;
                Ok(t)
            }
            "copy" | "move" => {
                files::transfer(&paths(&v)?, Path::new(strv(&v, "dir")?), cmd == "move")
            }
            "cut" => {
                let p = paths(&v)?;
                self.cancel_cut()?;
                let hide = self.config()?["hideOnCut"] == true;
                let mut items = vec![];
                for p in p {
                    files::protected(&p)?;
                    let m = fs::symlink_metadata(&p)?;
                    items.push(json!({"path":p,"flags":m.st_flags(),"inode":m.st_ino(),"device":m.st_dev()}));
                }
                files::atomic_json(&self.root.join("cut.json"), &json!(items))?;
                if hide {
                    for i in &items {
                        if let Err(e) = files::hidden(Path::new(i["path"].as_str().unwrap()), true)
                        {
                            self.cancel_cut()?;
                            return Err(e);
                        }
                    }
                }
                Ok(json!({"count":items.len()}))
            }
            "cancel_cut" => {
                self.cancel_cut()?;
                Ok(json!({"cancelled":true}))
            }
            "paste" => {
                let cut = self.cut_items()?;
                let list = cut.as_array().context("剪切状态错误")?;
                ensure!(!list.is_empty(), "没有待粘贴的文件");
                let mut p = vec![];
                for i in list {
                    let path = PathBuf::from(strv(i, "path")?);
                    let m = fs::symlink_metadata(&path)?;
                    ensure!(
                        m.st_ino() == i["inode"].as_u64().unwrap_or(0)
                            && m.st_dev() as u64 == i["device"].as_u64().unwrap_or(0),
                        "剪切后的文件已被替换，请重新选择"
                    );
                    files::set_flags(&path, i["flags"].as_u64().unwrap_or(0) as u32)?;
                    p.push(path);
                }
                let result = files::transfer(&p, Path::new(strv(&v, "dir")?), true)?;
                let left: Vec<_> = list
                    .iter()
                    .filter(|i| {
                        !result["completed"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .any(|c| c["source"] == i["path"])
                    })
                    .cloned()
                    .collect();
                files::atomic_json(&self.root.join("cut.json"), &json!(left))?;
                Ok(result)
            }
            "info" => Ok(
                json!({"files":paths(&v)?.iter().map(|p|files::info(p)).collect::<Result<Vec<_>>>()?}),
            ),
            "delete" => {
                ensure!(v["confirmed"] == true, "永久删除需要明确确认");
                let p = paths(&v)?;
                for p in &p {
                    files::protected(p)?
                }
                for p in &p {
                    files::remove(p)?
                }
                Ok(json!({"count":p.len()}))
            }
            "folder_from_name" => {
                let mut result = vec![];
                for p in paths(&v)? {
                    let dest = files::unique(
                        p.parent().unwrap(),
                        &p.file_stem().unwrap_or_default().to_string_lossy(),
                    )?;
                    fs::create_dir(&dest)?;
                    result.push(dest);
                }
                Ok(json!({"paths":result}))
            }
            "shortcut" => {
                let dir = files::directory(Path::new(strv(&v, "dir")?))?;
                let mut result = vec![];
                for p in paths(&v)? {
                    let dest = files::unique(&dir, &p.file_name().unwrap().to_string_lossy())?;
                    std::os::unix::fs::symlink(&p, &dest)?;
                    result.push(dest)
                }
                Ok(json!({"paths":result}))
            }
            "rename" => {
                let p = paths(&v)?;
                ensure!(p.len() == 1, "重命名请只选择一个文件");
                let dest = p[0].parent().unwrap().join(files::name(strv(&v, "name")?)?);
                files::rename_exclusive(&p[0], &dest)?;
                Ok(out(dest))
            }
            "hidden" => {
                let p = paths(&v)?;
                for p in &p {
                    files::hidden(p, v["hidden"] == true)?
                }
                Ok(json!({"count":p.len()}))
            }
            "writable" => {
                let p = paths(&v)?;
                for p in &p {
                    ensure!(!p.is_symlink(), "请对实际文件设置权限");
                    let mut perms = fs::metadata(p)?.permissions();
                    perms.set_mode(perms.mode() | 0o200);
                    fs::set_permissions(p, perms)?
                }
                Ok(json!({"count":p.len()}))
            }
            "dissolve" => {
                let mut result = vec![];
                for p in paths(&v)? {
                    files::protected(&p)?;
                    ensure!(p.is_dir() && !p.is_symlink(), "请选择实际文件夹");
                    let children = fs::read_dir(&p)?
                        .map(|e| Ok(e?.path()))
                        .collect::<Result<Vec<_>>>()?;
                    if !children.is_empty() {
                        let r = files::transfer(&children, p.parent().unwrap(), true)?;
                        ensure!(
                            r["errors"].as_array().unwrap().is_empty(),
                            "部分文件未移出：{r}"
                        );
                        result.extend(r["paths"].as_array().unwrap().clone());
                    }
                    fs::remove_dir(&p)?;
                }
                Ok(json!({"paths":result}))
            }
            "scan" => files::scan(Path::new(strv(&v, "dir")?)),
            "convert" => media::convert(
                &paths(&v)?,
                Path::new(strv(&v, "dir")?),
                strv(&v, "format")?,
            ),
            "qr" => media::qr(strv(&v, "text")?, Path::new(strv(&v, "dir")?)),
            "compress" => media::compress(
                &paths(&v)?,
                Path::new(strv(&v, "dir")?),
                v["format"].as_str().unwrap_or("zip"),
            ),
            "extract" => media::extract(&paths(&v)?, Path::new(strv(&v, "dir")?)),
            "archive7z" => archive::compress(
                &paths(&v)?,
                Path::new(strv(&v, "dir")?),
                v["format"].as_str().unwrap_or("7z"),
                v["password"].as_str().unwrap_or(""),
            ),
            "extract_auto" => {
                let p = paths(&v)?;
                let password = v["password"].as_str().unwrap_or("");
                if password.is_empty()
                    && p.iter()
                        .all(|p| p.extension().is_some_and(|x| x.eq_ignore_ascii_case("zip")))
                {
                    media::extract(&p, Path::new(strv(&v, "dir")?))
                } else {
                    archive::extract(&p, Path::new(strv(&v, "dir")?), password)
                }
            }
            "repair_preview" | "repair_apply" => {
                let p = paths(&v)?;
                let mut names = vec![];
                let mut changes = vec![];
                for p in &p {
                    let old = p
                        .file_name()
                        .context("无效文件名")?
                        .to_str()
                        .context("文件名不是有效 UTF-8")?;
                    let bytes = match v["encoding"].as_str().unwrap_or("latin1") {
                        "gbk" => {
                            let (b, _, err) = encoding_rs::GBK.encode(old);
                            ensure!(!err, "文件名不能表示为 GBK 字节");
                            b.into_owned()
                        }
                        "big5" => {
                            let (b, _, err) = encoding_rs::BIG5.encode(old);
                            ensure!(!err, "文件名不能表示为 Big5 字节");
                            b.into_owned()
                        }
                        _ => old
                            .chars()
                            .map(|c| {
                                ensure!((c as u32) <= 255, "文件名不是 Latin-1 乱码");
                                Ok(c as u8)
                            })
                            .collect::<Result<Vec<_>>>()?,
                    };
                    let name = String::from_utf8(bytes)
                        .context("该编码不适合当前文件名，请尝试另一种编码")?;
                    files::name(&name)?;
                    let dest = p.parent().unwrap().join(&name);
                    ensure!(dest == *p || !files::exists(&dest), "目标名称已经存在");
                    names.push(json!({"old":old,"new":name}));
                    changes.push(dest);
                }
                if cmd == "repair_preview" {
                    Ok(json!({"names":names}))
                } else {
                    for (src, dest) in p.iter().zip(&changes) {
                        if src != dest {
                            files::rename_exclusive(src, dest)?;
                        }
                    }
                    Ok(json!({"paths":changes}))
                }
            }
            "copy_path" | "copy_name" => {
                let text = paths(&v)?
                    .iter()
                    .map(|p| {
                        if cmd == "copy_name" {
                            p.file_name().unwrap().to_string_lossy().into_owned()
                        } else {
                            p.to_string_lossy().into_owned()
                        }
                    })
                    .collect::<Vec<String>>()
                    .join("\n");
                native(json!({"cmd":"clipboard","text":text}))
            }
            "native" => native(v["request"].clone()),
            _ => bail!("未知操作：{cmd}"),
        }
    }
}
