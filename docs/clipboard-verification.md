# 剪贴板迁移验收记录

日期：2026-11-12。环境：Apple Silicon、macOS 14.3、Swift 5.9.2、仓库固定 Rust 工具链、Python 3.12。功能及使用范围见 [使用说明](clipboard.md)，调研依据见 [Paste 功能清单](paste-feature-research.md)。

## 已通过

| 检查 | 结果 |
| --- | --- |
| Swift 剪贴板核心 | 113 项隔离检查：持久化、去重、格式与多文件恢复、富文本编辑与合并、正则/机密标记、保留期、固定板颜色及排序、快捷键校验、定时暂停、损坏/缺失数据处理、图片旋转及真实 Vision OCR；队列启动前补采、重复补采抑制和独立命名剪贴板 |
| MCP | 初始化与通知、分页和参数限制、默认禁用、仅收藏范围、额外历史权限、逐请求撤销、OCR、文件内容隔离、真实 stdio 子进程 |
| 打包后的 MCP 入口 | 实际调用 `RightClick --clipboard-mcp`，验证 Rust 到 Swift 导出、协议握手、三个工具、禁用时拒绝内容读取且不创建数据 |
| 队列数据结构 | 顺序、重复入队、反转、删除失效记录、消费及重新开始 |
| 原生界面隔离运行 | 紧凑界面 52 项持久回归检查：初始粘贴、方向键与纯文本、批量和取消勾选、分类与搜索、默认/最小窗口布局、滚动到底、搜索图标留白、输入法确认、左右分类循环、修饰键及搜索编辑保护 |
| Quick Look | 原生 QLPreviewView 创建、临时目录 0700 / 文件 0600、关闭后清理临时资料 |
| 链接预览 | 本机 HTTP fixture，只有点击后才加载；独立 nonPersistent WebKit，无主控制台桥接；HTTP/HTTPS 允许，file/data/javascript/ftp/about 拒绝 |
| 其他界面检查 | 固定板颜色和顺序刷新、搜索词背景高亮；940×620 最小窗口截图检查通过，图片可压缩且正文/按钮不裁切；既有控制台 10 项 Node 测试 |
| Rust | 19 项测试，Clippy `-D warnings` 通过 |
| Finder 回归 | 菜单复制、31 项层级、路由、磁盘监听、26 项真实 Rust 动作检查 |
| 打包回归 | 7 项发布校验单元测试、18 组图片/模板/加密归档 smoke 检查 |
| 构建与签名 | `scripts/build.py` 生成 `dist/RightClick.app`；`codesign --verify --deep --strict` 通过；`git diff --check` 通过 |

自动检查可重跑：

```sh
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTCLICK_7ZZ="$(python3 scripts/build_support.py)"
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
node --test tests/ui.cjs tests/menu-ui.cjs
python3 -m unittest discover -s tests -p 'test_release.py' -v
python3 scripts/build.py
python3 scripts/test_native.py
python3 scripts/smoke.py
codesign --verify --deep --strict dist/RightClick.app
```

构建脚本需要 Python 3.11+；上述检查使用已安装的 Python 3.12。测试使用临时资料目录和命名剪贴板／生成片段，不导入用户 Paste 数据，不开启用户历史采集，不更改系统权限。首轮构建产物保存在仓库 `dist`；随后按用户要求安装更新，记录如下。

## 安装更新

2026-11-12 已替换 `~/Applications/RightClick.app` 并重新启动。安装包与已测试的 `dist` 逐文件哈希一致，签名校验通过；新进程实际加载安装目录的原生库，安装版 MCP 隔离检查通过。原有资料文件在替换前后及重启后哈希一致，Finder 扩展仍显示已启用且仅登记一个安装路径。

旧版备份：`build/installation-backups/2026-11-12-004754/RightClick-before-clipboard.zip`。更新明细：`build/last-clipboard-installation.json`。图形操作服务当时无法启动，因此本次以进程、已加载原生库、签名和安装版协议验证启动结果，未额外声称完成界面点击验收。

## uTools 交互改造与安装版验证

2026-11-12 查看本机 uTools 8.0.0-beta.6 的实际剪贴板窗口。因图形控制服务启动失败，在用户明确授权后，使用 macOS Accessibility 读取控件、位置和尺寸，并发送测试输入；未修改 uTools 设置。屏幕录制权限尚未生效，因此此处是实际界面结构与交互观察，不是像素截图比对。

确认的参考交互：800×600 窗口、顶部即时搜索、全部/文本/图像/文件/收藏分类、内容列表及行内图片、右侧窄操作栏；单击记录切换勾选，显示已选数量，再次点击取消。验证搜索时只使用本任务生成的 `RC-LIVE-` 样例。

RightClick 已按此调整，并将日常不常用的来源/日期/固定板筛选及编辑操作收进筛选面板和更多菜单。默认及当前用户配置的唤出快捷键均为 `⌘⌥V`；保留自定义能力。另修复失去焦点后第一次快捷键仅隐藏旧窗口状态，以及开启顺序队列前刚复制的内容误入队列的问题。

新版已安装到 `~/Applications/RightClick.app` 并重启，逐文件哈希与 `dist` 一致，签名校验通过。旧版备份：`build/installation-backups/2026-11-12-011738/RightClick-before-compact-ui.zip`，安装明细：`build/last-clipboard-compact-installation.json`。记录保持开启、暂停关闭，保留现有资料和设置。

实际系统剪贴板测试：写入唯一的 `RC-LIVE-RECORD-…` 样例，运行中的安装版在 5 秒内自动记录；随后在剪贴板未被其他操作改变的前提下恢复原内容，并附临时标记防止恢复动作再录入历史。改造前安装版已验证 `⌘⌥V` 能唤出。

最初系统设置中的旧 RightClick 记录显示允许，但安装版仍报告权限不足。通过系统设置移除该失效记录，再从 `/Users/zhangxin/Applications/RightClick.app` 添加当前安装版并重启后，真实直接粘贴和队列测试通过。未改写系统权限数据库。

以下均针对实际安装版，通过 macOS 键盘事件和辅助功能完成；粘贴结果读取独立临时原生文本窗口中的真实文本，不以“成功发出按键”代替成功：

| 实机项目 | 结果 |
| --- | --- |
| `⌘⌥V` | 一次唤出、再次关闭，切换到其他应用后再次一次唤出，均通过；实际窗口800×600 |
| 直接粘贴 | 复制 `RC-LIVE-DIRECT`、搜索并回车，目标准确收到同样内容，焦点返回目标应用 |
| 顺序粘贴 | 开始队列后依次复制 A/B/C 样例，再按三次 `⌘V`，目标实际为 A+B+C，无重复/漏项 |
| 快速队列 | 以80毫秒间隔连续发出三次 `⌘V`，仍准确得到 A+B+C |
| 重复内容入队 | 依次复制 A/A/B，目标实际为 A+A+B，重复内容没有被队列去掉 |
| 新界面交互 | 7项实际输入检查：即时搜索、单击勾选、再次取消、连续单击多选、取消全部、图像分类排除文字、全部分类恢复记录 |

原始结果保存在 `build/clipboard-live-check/{direct,stack,rapid,duplicates,ui}-results.json`。测试结束后关闭临时窗口、清理精确匹配的未收藏测试条目，保留其他历史、设置和收藏。

## 尚未声称完成的实机验证

- 上述真实粘贴结果针对临时原生文本窗口；未逐一验收浏览器、终端、远程桌面和自定义编辑器。没有通用的应用粘贴完成回执，慢速或自定义目标应用仍可能需要手动核对。
- 录屏隐藏仅使用兼容窗口共享设置，未验证所有屏幕共享/录屏软件。共享屏幕前关闭内容窗口。
- macOS 14 没有 Apple Intelligence；本轮未实现 Paste 的智能上下文推荐，未验证新版系统写作工具。
- iCloud、共享固定板和 iOS 客户端按用户确认另做；本轮 MCP 为只读 stdio，未实现 Paste 的 HTTP/OAuth 及写入工具。

## 临时验收程序崩溃报告补充

用户随后提供 `ClipboardLiveTar` 的崩溃报告（事件 `F9AF75A0-E17B-43C5-AB55-92D1525E1CB2`）。事件发生于 2026-11-12 01:14:39，PID92937、coalition `dev.rustclick.livefixture`，属于仓库 build 目录中的临时文本接收窗口。最终15项实机结果文件生成于01:25–01:27，晚于这次事件；这次崩溃不能记作最终验收阶段通过，也不等同于 RightClick 主程序崩溃。

报告为 `EXC_BAD_ACCESS (SIGBUS) / KERN_MEMORY_ERROR`，访问地址 `0x10495a730` 位于文件映射区域。当前测试二进制 UUID 与报告一致，按报告映射基址换算偏移 `0xa730`，正好对应45字节的静态窗口标题“RightClick 粘贴验收 · 临时文本窗口”。故障发生在 AppKit 绘制标题、Swift读取这个静态字符串时，不是读取用户剪贴板文本。测试可执行文件的创建/修改时间均为01:00:11，没有运行中重新编译覆盖的证据。

[Apple 的异常说明](https://developer.apple.com/documentation/xcode/investigating-memory-access-crashes)将 `KERN_MEMORY_ERROR` 定义为访问当时无法返回数据的内存，例如已不可用的文件映射。这支持程序文件映射页读取失败；程序来自外置USB卷，但现有日志未能将该卷的具体断连或I/O错误与崩溃直接对应，不能断言硬盘损坏。附近确有另一USB存储桥的重连日志，设备映射不同，未将其误作该程序所在卷的证据。

核查时临时程序已退出，RightClick 主进程仍在安装目录运行，深度签名检查通过；用户 DiagnosticReports 目录未发现 RightClick/RustClick 主程序报告。本次仅做报告与系统日志核对，未通过断开磁盘复现，也未据此修改或重新安装主程序。

## 搜索框布局与中文输入法回车修复

2026-11-12 修复搜索框获得焦点后提示文字与搜索图标重叠，以及中文输入法确认输入时误粘贴首条记录两个问题。

无边框搜索框的原生文字编辑器原先占据整个控件区域；默认尺寸下为 `(0,0,597,16)`，覆盖了图标。自定义搜索框 cell 的 `select` 和 `edit` 入口后，编辑器使用原生 `searchTextRect`，默认尺寸为 `(25,0,551,16)`，最小窗口尺寸为 `(25,0,431,16)`。鼠标进入编辑、键盘聚焦、窗口缩放和已输入中文的布局均已检查，提示文字与图标分开。

本地键盘事件监听原先在输入法之前拦截 Return 并粘贴。现在先检查当前文字输入对象是否仍有组字内容；有组字时原样放行事件，由输入法处理确认、候选项导航与取消。输入确认结束后，后续独立 Return / Shift-Return 仍执行普通／纯文本粘贴。修复前隔离复现能检出回车误粘贴和编辑器覆盖图标，修复后通过；`tests/clipboard-panel-main.swift` 共26项检查通过，其中组字检查使用真实字段编辑器的 marked text 和 `NSApp.sendEvent`，覆盖本地事件监听路径。

更新已安装到 `/Users/zhangxin/Applications/RightClick.app` 并重启。安装文件与 `dist` 逐文件哈希一致，深度签名校验通过。旧版备份：`build/installation-backups/2026-11-12-021150/RightClick-before-search-fix.zip`；安装记录：`build/last-clipboard-search-installation.json`。

安装版实测沿用本机当前微信输入法 `com.tencent.inputmethod.wetype.pinyin`，临时接收程序和操作助手放在内置磁盘临时目录。按实体键输入 `zhong` 后，第一次 Return 只确认搜索输入：查询仍为 `zhong`、历史面板保持打开、目标文本仍为空；再次单独按 Return 后，目标准确收到 `RC-LIVE-IME-zhong-中文确认`，没有权限提示。结果文件 `build/clipboard-search-ime-live-results.json` 的5项均通过。此结果针对微信输入法及临时原生文本窗口，不代表已遍历所有输入法和目标应用。

本轮也核实了反复授权的原因：`scripts/build.py` 和 `scripts/package.py` 仍硬编码 ad-hoc 签名，安装版的指定要求绑定当前代码哈希；更新构建后，旧授权可能无法匹配新程序。[Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) 说明了此类签名无法可靠地跨版本保持隐私授权。此次通过用户在系统设置中的验证及重新添加当前应用完成验收，未改写权限数据库。长期方案需要配置稳定签名证书并统一构建、打包的签名身份；本轮未创建或更改证书，也未声称已解决后续更新的授权延续问题。

## 左右方向键切换分类修复

2026-11-12 补上历史面板的左右方向键导航。此前键盘处理只包含上下选记录，没有左右切分类；在真实本地事件监听路径添加空搜索框聚焦后的 Right 检查，原实现失败，修复后通过。

空搜索框或结果列表获得焦点时，`←`、`→` 在全部、文本、图像、文件、收藏间循环切换，复用鼠标点击分类的筛选与取消勾选逻辑。保留当前查询和输入焦点；有搜索文字时，搜索框里的左右键继续移动光标。中文组字优先交给输入法；Command、Option、Control、Shift 组合方向键不切分类。普通硬件方向键携带的 function/numericPad 标记及 Caps Lock 不影响分类切换。页脚增加分类导航提示。

`tests/clipboard-panel-main.swift` 共52项隔离检查通过，包括双向边界循环、空分类、筛选结果数量、焦点和查询保留、组合键与中文组字保护。隐藏测试窗口不能可靠地执行未拦截按键的原生光标行为，因此该项另外通过安装版实测：输入 `123`，左键将插入点从3移到2，右键再回到3，分类和查询均不变。

安装版实机14项分类与光标检查通过（`build/clipboard-tab-live-results.json`），另验证「更多」菜单打开后方向键不会切换背景分类（`build/clipboard-tab-menu-live-results.json`）。测试使用当前已保存的面板快捷键，不改用户快捷键配置、不写通用剪贴板、不刷新系统授权。

更新已安装至 `~/Applications/RightClick.app` 并重启，逐文件哈希与 `dist` 一致，深度签名校验通过。旧版备份：`build/installation-backups/2026-11-12-023014/RightClick-before-tab-fix.zip`；安装记录：`build/last-clipboard-tab-installation.json`。本轮未配置签名证书，仍为临时签名，未重新验收跨应用直接粘贴权限。
