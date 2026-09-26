# RightClick

一个 Rust 驱动的 macOS 桌面右键工具箱。所有功能免费，无账号、无订阅、无激活校验。

参考用户提供的 [iRightMouse 功能说明](https://github.com/wtkvhyp/irightmouse)，并实际查看本机超级右键 2.4.9 的通用设置、新建文件、发送文件、文件图标和工具箱页面后独立实现。没有复制其程序、图标、文档模板或授权系统，与 Better365 无关联。

## 开始使用

从 [GitHub Releases](https://github.com/zachaxy/right-click/releases/latest) 下载 DMG 安装包，打开后将 `RightClick.app` 拖到 Applications（应用程序）文件夹。也可下载 ZIP 解压安装。当前提供 Apple Silicon、macOS 14+ 版本，详细步骤见 [安装说明](docs/INSTALL.zh-CN.txt)。

通过构建脚本的 `--install` 参数安装时，应用位于个人目录 `~/Applications/RightClick.app`，与系统的 `/Applications/` 不同。开发构建产物位于 `dist/RightClick.app`。

RightClick 以菜单栏应用运行，不在 Dock 中显示。**单击顶部 RightClick 图标**打开控制台，**右键图标**可打开或退出应用；关闭控制台窗口后仍在后台提供访达右键功能。菜单栏图标可在“通用设置”中开关。

1. 打开 RightClick。应用内“操作台”无需访达扩展即可处理文件。
2. 在系统设置的“隐私与安全性 → 扩展 → 访达扩展”中启用 **RightClick Finder**。新版 macOS 的入口可能位于“通用 → 登录项与扩展”。应用“通用设置”也提供系统入口。
3. 访达中右击文件或空白处，默认进入 **RightClick** 子菜单。可在控制台的 **右键菜单** 页面调整各个功能的层级。窗口工具栏右击 → 自定义工具栏，可添加 **RightClick** 按钮。
4. 根据需要授予完全磁盘访问、自动化或辅助功能权限。RightClick 不绕过系统权限，也不要求为普通文件操作一次性授予所有权限。

“前往授权”只打开完全磁盘访问设置页。如果列表中没有 RightClick，请点击“＋”并选择实际安装的 `RightClick.app`。使用 `--install` 安装的用户可在选择窗口按 `⌘⇧G`，输入 `~/Applications/` 找到应用；启用后按系统提示重新打开应用。

访达菜单只有“打开 RightClick 操作台”会显示主控制台。其余操作按需要直接执行或使用独立窗口：

- 拷贝路径/名称、剪切粘贴、指定目标目录的复制/移动、格式转换、普通压缩等在后台执行。
- 新建、重命名、加密压缩、解压、图标设置使用小型参数窗口；选择目标目录时使用系统目录选择器。
- 文件信息、校验值、目录空间和错误使用独立结果窗口，可拷贝结果、在访达中定位文件。
- 删除和解散文件夹保留确认流程（永久删除仍遵循用户的确认偏好）；取消窗口不会提交操作。
- 需要打开终端、编辑器、预览或常用目录时，直接打开目标应用。后台处理和短暂完成提示不会激活主控制台。应用未启动时也可从访达菜单使用。

## 配置右键菜单层级

打开控制台 → **右键菜单**，搜索功能或展开分组。**分组位置**与**子项位置**分别设置：

| 层级 | 访达中的位置 | 示例 |
| --- | --- | --- |
| 一级 | 分组或功能直接显示 | 新建文件；新建 Markdown |
| 二级 | 一级分组内的子项，或 RightClick 内的功能 | 新建文件 → Markdown |
| 三级 | RightClick 内分组的子项 | RightClick → 新建文件 → Markdown |

例如，将“新建文件”的**分组位置**设为一级，选择“跟随分组”的格式、模板和以后新增的模板就会出现在其二级菜单中。再将“新建 Markdown”单独设为一级，它会直接出现在右键菜单，其他子项继续留在“新建文件”内。分组放在二级时，默认子项在三级。

修改分组位置不会覆盖子项的单独设置。“子项跟随分组”可清除该分组所有子项的单独设置；也可只将一个子项改为“跟随分组”。修改自动保存，下次打开右键菜单生效，无需重启访达。同一功能只出现一次；离开分组的动作使用“新建 Markdown”“复制到 文稿”等完整名称。页面顶部统计各层级的功能数量，不包含分组入口。

页面同时提供分组显示开关和排序。隐藏开关优先于层级设置；禁用的文件格式或模板不会因调整层级而重新显示。新增模板、常用目录和应用会自动加入列表。“恢复默认层级”清除分组和子项的位置选择，不改变顺序和开关。旧版单项位置会保留；旧版批量平铺的子项可通过“子项跟随分组”收回。

## 功能

- **新建文件**：TXT、Markdown、Word、Excel、PowerPoint、RTF、XML、JSON、HTML、Rust、Python、Shell、SVG、PSD、AI（EPS 兼容格式）；自定义任意文件名和扩展名；导入任意文件或文档包作为模板。
- **文件管理**：批量复制/移动、剪切与粘贴、取消剪切、常用目录、重命名、按文件名建目录、解散目录、桌面符号链接、文件隐藏和扩展名显示、当前用户写权限、移到废纸篓、永久删除。
- **开发工具**：终端/iTerm2 新窗口或新标签页、VS Code、Typora、JetBrains、Obsidian 等；可以添加任何已安装应用。
- **图片**：PNG/JPG/WebP/HEIC/ICNS 转换、Mac iconset、iOS appiconset、文件夹颜色与自定义图片图标、恢复图标、预览标注、浮动贴图、系统交互截图、设为墙纸。
- **归档**：ZIP、7z、AES-256 加密 ZIP/7z、解压到独立目录；密码仅用于本次操作。
- **其他工具**：流式 MD5/SHA1/SHA256/SHA512 校验、目录空间扫描、乱码文件名预览修复、AirDrop、离线二维码、浏览器翻译、系统文字服务。
- **偏好**：分组的一级/二级位置、子项跟随分组或单独指定一级/二级/三级、菜单顺序、菜单开关/图标、模板管理、外接磁盘、云盘 Shift+右键或鼠标中键菜单、隐藏菜单栏图标、登录启动、新建后自动打开、提示音、剪切时可保持文件可见、可关闭永久删除确认。

文件复制使用 macOS `ditto` 保留扩展属性和资源叉；最终发布使用 `renamex_np(RENAME_EXCL)` 防止覆盖。跨磁盘移动先复制，再移除源。批量复制/移动返回逐项结果，剪切仅清除成功粘贴的项目。ZIP 解压拒绝越界路径、重复条目和符号链接；7z 解压先校验条目，再写入临时目录。解压限制为 100,000 个条目以内、20 GB 以内。

## 范围与限制

- **此版本是 macOS Apple Silicon 版本**；需要 macOS 14+（内置 7zz 的最低系统要求）。未构建 Windows/Linux/Intel 发行包。
- **Pages / Numbers / Keynote / WPS 原生格式**通过导入自己的模板支持，没有附送这些专有格式的空白模板。AI 内置模板为 EPS 兼容文本，不伪造 Adobe 原生模板。
- 云盘快捷入口实现 **Shift+右键和鼠标中键**，未实现三指触控板轻拍；不会修改系统触控板手势。
- 截图使用 macOS 系统选区工具；图片标注调用“预览”，贴图由独立浮动窗口提供；不依赖 iShot 或 FastZip，也不包含它们的高级专用编辑器。
- 磁盘扫描为只读空间统计，不提供自动清理系统垃圾。没有云账号同步；配置保存在本机。
- “显示隐藏文件”写入访达偏好；部分 macOS 版本需要重新打开或重启访达才能刷新。
- 符号链接不参与归档，以避免解压时链接逃逸；普通文件复制可保留符号链接。解压为独立目录，不自动删除原归档。
- 外接硬盘、云盘、登录启动、AirDrop、壁纸、自动化、截图依赖当前设备和系统授权。代码已实现，并不代表这些入口在所有硬件/系统版本上均完成实机验证。
- 使用本地 ad-hoc 签名，**未经过 Developer ID 签名或 Apple 公证**。接收者首次打开可能需要在系统设置中确认；若要免去未公证提示，需要 Developer ID 证书和 Apple 公证。

验证记录见 [验收记录](docs/verification.md)。

## 构建

需要 Apple Silicon Mac、Rust/rustup、macOS Command Line Tools（Swift/Cocoa）和 Python 3.11+。Rust 版本由 `rust-toolchain.toml` 固定；7z 从 Homebrew 官方下载固定的 26.03 Sonoma/arm64 bottle 并校验 SHA-256，不依赖本机 Homebrew 版本。

```sh
export PATH="$HOME/.cargo/bin:$PATH"
python3 scripts/build.py --install
```

输出：`dist/RightClick.app`。`--install` 安装到 `~/Applications` 并向 LaunchServices / PlugInKit 注册，不替用户启用系统权限。修改后构建时应先退出 RightClick。

### 生成分发安装包

```sh
python3 scripts/package.py
```

重新构建后生成 `dist/RightClick-<版本号>-arm64.dmg`、ZIP 和 SHA-256 校验文件。版本号统一读取 `Cargo.toml`，并写入应用、访达扩展和界面。DMG 内有应用、指向“应用程序”的快捷方式和中文安装说明；拖动安装即可，接收者不需要开发环境。包内附带 RightClick 与 Rust 依赖许可证，以及 7-Zip 26.03 对应源码和构建说明。不打包本机偏好、模板、历史记录或开发目录。

脚本检查架构、最低 macOS 版本、动态库依赖和签名，创建镜像后只读挂载，逐文件比对并从镜像执行隔离的文件新建、加密压缩及解压检查。完整接收者说明见 [安装说明](docs/INSTALL.zh-CN.txt)。

```sh
export RUSTCLICK_7ZZ="$(python3 scripts/build_support.py)"
cargo test
cargo clippy --all-targets -- -D warnings
python3 -m unittest discover -s tests -p 'test_release.py' -v
node --test tests/ui.cjs tests/menu-ui.cjs
python3 scripts/smoke.py
# Finder 菜单层级与参数、窗口路由和真实 Rust 操作流程
python3 scripts/test_native.py
```

首次运行会从 Rust 官方源、crates.io、Homebrew 获取构建依赖。应用运行时不需要 Rust、Node 或 Python。

### GitHub 自动发版

推送 `vX.Y.Z` 标签会触发 [Release 工作流](.github/workflows/release.yml)，在 macOS ARM64 环境中运行测试、构建和验证，再创建 Release 并上传 DMG、ZIP、SHA-256 文件。流程使用 GitHub 自动提供的令牌，不需要配置个人访问令牌。

以发布 `v0.1.1` 为例：

1. 将 `Cargo.toml` 的版本改为 `0.1.1`，运行 `cargo check` 更新 `Cargo.lock`。
2. 编写 `docs/releases/v0.1.1.md`，记录本次功能、修复、安装要求和已知限制。
3. 提交版本与说明文件，推送代码，再创建并推送标签：

```sh
git push origin main
git tag -a v0.1.1 -m "RightClick v0.1.1"
git push origin v0.1.1
```

在仓库的 Actions → Release 中查看进度；成功后可在 Releases 下载新版本。标签必须与 `Cargo.toml`、`Cargo.lock` 一致，且存在非空的对应发版说明。目前只支持正式版 `X.Y.Z`，不接受预发布后缀。

应用和扩展的内部构建号也从同一版本派生，主版本加一，例如 `0.1.1` 对应构建号 `1.1.1`，确保高于早期固定构建号 `1`。对用户显示的版本仍为 `0.1.1`。

也可以在 Actions → Release → Run workflow 手动运行完整构建验证。**手动运行不会创建 Release**，安装包和验证报告保存在该次运行的 Artifacts 中，保留 14 天。普通代码推送不会自动发版，`dist/` 继续由 Git 忽略。

工作流不会覆盖已发布的同名版本。如果上传中断留下草稿，先确认并删除对应草稿，再重跑失败任务；已经正式发布的版本应使用新版本号。自动构建沿用 ad-hoc 签名，Developer ID 签名和 Apple 公证需另外配置。

## 结构

```text
src/                    Rust 引擎、文件/归档/图片/模板、CLI 和 FFI
native/App.swift        AppKit 窗口、WebKit、系统能力的薄适配层
native/FinderSync.swift Finder 右键和工具栏扩展
native/FinderVolumeMonitor.swift 登记已挂载磁盘，并在插入、卸载和改名时更新监听目录
native/FinderMenu.swift 控制台共享功能目录、每个动作的菜单层级与显示规则
native/MenuActionStore.swift 通过 tag 保留系统复制后的菜单动作
native/FinderRequestRouting.swift 显式操作台与独立操作分发
native/FinderActions.swift 菜单参数处理、确认及 Rust 引擎调用
native/FinderActionUI.swift 独立输入/结果窗口、目录选择及后台提示
ui/                     本地中文界面；不加载远程内容
scripts/                编译、签名、安装和打包验证
```

主进程是 Rust 可执行文件，通过 C ABI 调用 Swift 原生界面动态库。文件操作在串行后台队列中运行。访达扩展在沙盒中获取用户当前选择，通过一次性命名剪贴板和 `rustclick://` 请求唤起主应用；不占用普通剪贴板。菜单配置通过独立命名剪贴板更新。来自菜单的操作直接进入原生操作层和 Rust 引擎，不依赖网页加载；保留文件校验、删除确认和错误反馈。

为兼容已有安装，内部 bundle ID、通信协议及配置目录保持不变。配置及剪切恢复数据：`~/Library/Application Support/RustClick/`。关闭窗口会保留后台进程；右键顶部菜单栏图标选择“退出 RightClick”。剪切尚未粘贴时可在下次启动后取消剪切，恢复隐藏标志。

## 许可

RightClick 源码采用 MIT 许可，见 [LICENSE](LICENSE)。Rust 依赖的许可由各自 crate 声明。7-Zip 单独打包并以子进程调用，遵循其 LGPL/BSD/unRAR 许可，见 [7ZIP-LICENSE.txt](assets/7ZIP-LICENSE.txt)。对应源代码来自 [7-Zip 官方仓库](https://github.com/ip7z/7zip)，打包版本为 26.03；未修改其代码。
