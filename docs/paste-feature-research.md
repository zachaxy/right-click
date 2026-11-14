# Paste 功能调研与 RightClick 迁移对照

调研日期：2026-11-12。依据 Paste 官方帮助、官网和用户提供的 App Store 页面，未安装或实际操作 Paste。用户已确认本轮迁移 Mac 本地功能，跨设备功能另做。下文先列 Paste 的完整公开功能，再记录 RightClick 的本轮范围及差异；交付测试结果见 [验收记录](verification.md)。

Paste 是把“系统剪贴板只能保存当前内容”扩展成“可以查找、整理、重复使用的内容库”的工具。其功能不仅包括历史列表，也包括跨应用粘贴、跨设备同步、协作与 AI 接入。

## 功能清单

| 类别 | Paste 的功能 | 依据 |
| --- | --- | --- |
| 自动记录 | Mac 后台记录文字、链接、图片、文件和颜色；关闭窗口后继续记录。 | [采集范围](https://pasteapp.io/help/what-paste-captures) |
| 颜色识别 | 单独的六位十六进制色值展示色块；纯六位数字保留为文字，避免把验证码识别成颜色。 | [采集范围](https://pasteapp.io/help/what-paste-captures) |
| 格式保留 | 默认保留复制内容的原格式，也可单次或默认以纯文本粘贴。 | [纯文本粘贴](https://pasteapp.io/help/paste-as-plain-text) |
| 历史保留 | 可选 1 天、1 周、1 月、1 年或永久；默认 30 天；过期清理和清空历史保留已固定条目。 | [历史保留](https://pasteapp.io/help/control-history-retention) |
| 可视化浏览 | 按时间展示卡片，预览内容、来源应用和复制时间；底部面板支持调节高度、紧凑显示和当前屏幕定位。 | [Mac 使用指南](https://pasteapp.io/help/paste-on-mac) |
| 内容预览 | 行内预览及空格 Quick Look；链接可在内置浏览器预览；文件、图片和 PDF 等可查看。 | [Mac 使用指南](https://pasteapp.io/help/paste-on-mac) |
| 搜索与筛选 | 即时搜索历史及固定内容，按内容类型、来源应用、日期、设备筛选；可从结果跳转到所属列表。 | [搜索与筛选](https://pasteapp.io/help/search-and-filters) |
| 图片文字搜索 | 识别截图、照片中的文字并用于检索，结果可高亮匹配文字。 | [搜索与筛选](https://pasteapp.io/help/search-and-filters) |
| 全局唤起 | 默认 ⇧⌘V 显示或隐藏面板；也可从菜单栏打开。部分全局快捷键和修饰键可配置。 | [快捷键](https://pasteapp.io/help/keyboard-shortcuts) |
| 快捷粘贴 | Return 粘贴；⌘1–9 快速使用可见条目；Shift 修饰可变为纯文本；支持键盘导航、搜索、编辑和删除。 | [快捷键](https://pasteapp.io/help/keyboard-shortcuts) |
| 直接粘贴 | 将选中条目插入之前使用的应用；需辅助功能权限。无权限时复制回剪贴板，由用户手动粘贴。 | [直接粘贴](https://pasteapp.io/help/paste-directly-to-other-applications)、[Mac 使用指南](https://pasteapp.io/help/paste-on-mac) |
| 多选与拖拽 | 多选条目一起粘贴；可把内容拖入其他应用。 | [Mac 使用指南](https://pasteapp.io/help/paste-on-mac) |
| Paste Stack | ⇧⌘C 开始收集，随后复制的内容按序入栈；连续 ⌘V 逐条粘贴并移除已用条目；可反转方向及删除条目。 | [Paste Stack](https://pasteapp.io/help/using-paste-stack) |
| Pinboards 收藏板 | 建立有名称和颜色的分组；固定常用片段、模板、代码、图片；内容不受历史期限影响；支持移动、排序及批量固定。 | [Pinboards](https://pasteapp.io/help/organize-with-pinboards) |
| 编辑与标签 | 原位编辑文字并保留格式；重命名条目便于查找；图片有旋转、文字提取等操作。 | [编辑和标签](https://pasteapp.io/help/edit-items-before-pasting) |
| 系统写作工具 | 支持的设备上，编辑文字时可调用 Apple Intelligence 写作工具。 | [编辑和标签](https://pasteapp.io/help/edit-items-before-pasting) |
| 暂停与排除 | 可暂停采集并选择恢复时间；按应用排除；跳过应用标记的临时、机密内容；排除规则不会删除旧记录。 | [排除应用](https://pasteapp.io/help/exclude-apps) |
| 录屏隐私 | 提供屏幕共享、录屏时隐藏 Paste 的选项。官方描述不等于所有录制软件、系统版本均有同等效果。 | [App Store](https://apps.apple.com/cn/app/id967805235?platform=mac) |
| 本地数据 | 历史、收藏和索引在设备上保存；启用同步后副本进入私人 iCloud，非 Paste 自有服务器。 | [隐私政策](https://pasteapp.io/privacy) |
| iCloud 同步 | 历史和收藏板跨 Mac、iPhone、iPad 同步；每台设备单独开启，使用相同 Apple 账户。 | [同步说明](https://pasteapp.io/help/icloud-sync-doesn-t-work) |
| 共享收藏板 | 通过 iCloud 邀请协作者，设置只读或编辑、指定成员或链接访问，管理成员及停止共享。 | [共享收藏板](https://pasteapp.io/help/shared-pinboards) |
| iPhone / iPad 配套 | 移动端历史、搜索、编辑，分享扩展及主屏小组件；iPhone 后台不能自动持续读取剪贴板，iPad 在可见时可采集。 | [iPhone 指南](https://pasteapp.io/help/paste-on-iphone)、[移动端采集限制](https://pasteapp.io/help/clipboard-history-on-iphone) |
| Paste Keyboard | iOS 键盘扩展访问历史和收藏，粘贴、拖拽、纯文本处理；启用需要完整访问权限。 | [Paste Keyboard](https://pasteapp.io/help/enable-and-use-paste-keyboard) |
| 设备接力 | 与通用剪贴板配合，并支持设备间接续使用内容。 | [App Store](https://apps.apple.com/cn/app/id967805235?platform=mac) |
| 本地 MCP | Mac 内置本地服务，让获准的 Claude、Codex、Cursor 等工具搜索、使用历史和整理收藏；可管理和撤销访问。 | [Paste MCP](https://pasteapp.io/help/paste-mcp) |
| 智能推荐 | 根据正在处理的工作推荐历史条目，在 Mac 上运行；需 macOS 26+ 和已启用的 Apple Intelligence，屏幕上下文涉及录屏权限。 | [Intelligent Clipboard](https://pasteapp.io/help/intelligent-clipboard) |
| 备份与换机 | 官方推荐 Time Machine 或 iCloud 搬迁历史；未找到官方通用导出格式或向第三方迁移接口的承诺。 | [备份与迁移](https://pasteapp.io/help/where-paste-stores-your-data) |

## 会影响迁移的细节

- **这是功能迁移，不是 Paste 用户数据导入。** 本次不读取 Paste 私有数据库，不使用其商标、图标、界面素材或私有实现。
- **收藏有持久语义。** 历史过期和清空不能把固定条目一起删掉；Paste 一个条目同一时刻属于一个收藏板，固定后也仍出现在历史中。[Pinboards](https://pasteapp.io/help/organize-with-pinboards)
- **敏感内容过滤有边界。** 官方也说明部分密码管理器浏览器扩展未提供可检测的标记；不能承诺“密码绝不被记录”。RightClick 应过滤机密/临时类型并支持应用排除。[排除应用](https://pasteapp.io/help/exclude-apps)
- **MCP 会让内容进入获准 AI 工具。** “本地服务”不代表下游模型一定离线；应默认关闭、限制访问范围并允许撤销，不能让任意本地网页读取剪贴板。[Paste MCP](https://pasteapp.io/help/paste-mcp)
- **同步不是把一个 JSON 文件放进 iCloud。** 删除传播、冲突、附件、离线合并和共享权限均需实现。以下技术拆分为迁移判断，不是对 Paste 内部架构的推断。

## RightClick 实施拆分

本仓库现有 README 描述为 macOS 14+、Apple Silicon、Rust 引擎与 Swift/AppKit 适配、本地 WebKit 控制台，使用 ad-hoc 签名。迁移建议如下；此表是工作范围拆分，不作为已完成声明。

| 范围 | 建议落地方式 | 完成判断 |
| --- | --- | --- |
| 本机采集、历史和类型恢复 | 在 Swift 主应用监听普通剪贴板；本地保存条目及原始格式、来源和时间；文件记录明确是路径引用还是内容副本 | 重启仍存在，原格式能恢复，图片和多文件可用 |
| 搜索、OCR、分组、编辑 | 独立历史面板和控制台入口；系统 Vision 处理图片文字；收藏保留策略与历史分开 | 搜索含 OCR，筛选正确，删除/清空不误删收藏 |
| 原格式/纯文本/直接粘贴 | 恢复 NSPasteboard 数据，记录此前目标应用；辅助功能获准才派发粘贴事件 | 有权限可插入，无权限明确告知已复制，无静默丢失 |
| Stack 与快捷键 | 全局唤起、排队、逆序和逐条消费分别验证；处理用户新复制、快捷键占用和权限撤销 | 顺序正确，失败不丢队列，无法实现自动 ⌘V 时明确标为手动队列 |
| 隐私与持久化 | 开关、暂停、排除应用、机密/临时类型过滤；采集前过滤；限制本地数据访问 | 敏感标记不落盘，暂停不补录，坏数据不会静默覆盖有效历史 |
| iCloud 与协作 | 需要项目自己的 CloudKit 容器、签名能力、同步模型、共享参与者管理及多设备验证 | 仅有界面开关或本地收藏不能算已完成 |
| iOS 键盘、分享、小组件 | 需要新增 iOS/iPadOS App 与扩展目标，单独构建和设备测试 | macOS 工程无法直接提供手机键盘 |
| MCP | 独立、默认关闭的本地接口；限定可访问内容，认证和撤销；协议兼容测试 | 搜索/读取经过授权，可停止服务，错误请求不会泄露任意文件 |
| Apple Intelligence | 写作工具与推荐分别评估；按系统和模型可用性显示能力，保留 macOS 14 基础功能 | 普通按来源排序不能宣称等价智能推荐 |

## 建议验收场景

1. 复制中文、网址、富文本、截图和多个 Finder 文件，重启后验证预览与恢复。
2. 搜索标题、正文、来源应用及图片内中文；叠加日期和类型过滤。
3. 固定条目后清空普通历史，确认收藏保留；编辑文本及名称后重启核对。
4. 暂停时复制内容，恢复后确认未补采；过滤机密和临时类型；验证排除应用。
5. 在普通文本编辑器验证直接/纯文本/快捷键粘贴；撤销权限后有可理解的退化行为。
6. 队列按收集顺序消费、逆序、重复复制、移除及粘贴失败，确认没有跳项或重复。
7. 同步、协作、MCP 和 AI 必须分别列明启用条件及实测状态，不能与本地历史合并宣称完成。

## 本轮 Mac 本地实现与差异

RightClick 使用自己的原生列表和预览面板接入这些能力，并未复刻 Paste 的底部横向卡片界面。下表区分本轮本地实现、明确的行为差异以及另行开发的功能；“实现”不代表已经在所有目标应用、系统版本及设备上实测。

| 项目 | 本轮实现及范围 |
| --- | --- |
| 记录和存储 | 可开启或暂停后台采集；支持文字、链接、图片、文件和颜色；保存本机历史、来源及时间。记录默认关闭，开启前的旧剪贴板不会补采。单条支持的数据上限为 32 MB。 |
| 历史与查找 | 本地持久化、去重、保留天数、清空普通历史；固定内容不受历史保留期限影响。关键词匹配正文、标签、来源及 OCR，按类型、来源应用、时间和固定板筛选。 |
| 图像文字 | 使用本机 Vision 识别 PNG/TIFF 图像文字；可搜索及提取识别结果。并非所有图片都能正确识别，也不等同于 PDF 全文索引。 |
| 固定板 | 命名分组、固定与解除固定、重命名及删除。当前支持一个条目属于多个固定板；删板解除该板的固定关系，内容按普通历史期限保留。与 Paste 的单板归属、删板语义不同。 |
| 文件历史 | 保存文件位置和剪贴板表示，**不备份文件本体**；原文件移动、删除或不可访问后，无法靠剪贴板历史恢复文件。 |
| 面板与交互 | 独立列表、内容预览、键盘选择、快速粘贴、搜索、标签及拖入/拖出。没有 Paste 底部横向卡片布局；支持固定板颜色、固定板前后移动和板内条目上下移动；排序使用菜单操作。 |
| 预览边界 | 提供文本、图片、色块及文件列表预览；支持列表空格 Quick Look、整组文件切换预览、搜索文字高亮；链接在明确点击“预览链接（联网）”后由独立 WebKit 窗口加载。位图可向右旋转 90°，多页 PDF 不做该转换。 |
| 编辑与格式 | 原生富文本编辑器保留 RTF/RTFD 文字样式；支持原始格式粘贴、纯文本粘贴和默认纯文本偏好。多条文字按顺序合并时保留能解析的 RTF/RTFD 样式；只有 HTML 表示时，编辑和合并使用提取的文字，不承诺完整保留网页排版。 |
| 快捷键与暂停 | RightClick 默认使用 ⌥⌘V 唤出，避免与 uTools 的剪贴板快捷键冲突。可配置面板、队列及粘贴下一条三个全局快捷键，支持清除和恢复默认；面板内提供 ⌘1–9 快速粘贴及 Shift 纯文本操作。暂停可选 5、15、60 分钟或手动恢复。 |
| 权限与目标应用 | 直接粘贴需要辅助功能权限；无权限时可复制后手动粘贴。目标应用拒绝粘贴、焦点切换、硬件快捷键或系统权限会影响结果，不宣称任意应用均自动插入成功。 |
| 顺序粘贴 | 开始收集后按复制顺序入队，重复复制也入队；支持逆序、下一条和结束。通过事件监听串行派发普通 ⌘V；权限失效或遇到未记录的新剪贴板内容时保留新内容并停止队列。系统没有通用的粘贴完成回执，目标应用端行为未逐项实机验收。 |
| 本地 MCP | `--clipboard-mcp` 启动只读 stdio 子进程；提供搜索、读取单项、列出固定板三个工具。默认禁用；开启后默认只读固定板，全部历史另设开关；后续请求重新读取权限，可立即撤销后续访问。 |
| MCP 边界 | 仅提供存好的文字、OCR 及元数据；不打开文件目标或访问网址。搜索最多 50 项，预览最多 512 字符，单项正文和 OCR 合计最多 16,000 字符。采用同一系统用户启动的子进程信任边界，**不是 HTTP 服务，不提供 OAuth、逐客户端授权或创建/编辑固定板工具**。内容交给 AI 客户端后，是否上传云模型取决于该客户端。 |
| 隐私规则 | 机密/临时剪贴板标记在存储前跳过；支持应用排除、文字正则和暂停。来源应用由系统当时的前台应用推断，不保证覆盖所有后台或浏览器扩展复制路径。图片先保存再做异步 OCR，命中内容正则后才删除，不能把 OCR 过滤描述为“敏感图片从未落盘”。 |
| 屏幕捕获 | 不能把 `NSWindow.sharingType = .none` 当作录屏隐藏保证。Apple 当前将其描述为旧常量，并明确不应依赖它排除屏幕采集；实际隐私模式和验证范围以本轮验收说明为准。[Apple 文档](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none) |
| AI 推荐与写作工具 | 未迁移 Paste 基于 Apple Intelligence 的场景推荐，也未以普通排序冒充智能推荐。编辑器使用原生 NSTextView，系统右键文字工具可随系统能力提供；本轮不宣称已验收新版 Apple Intelligence Writing Tools。 |
| 跨设备 | 按用户确认另做：iCloud、共享固定板、iPhone/iPad App、键盘/分享扩展、小组件及设备接力。当前没有启用云端同步。 |

本轮为独立功能实现，未读取或导入 Paste 私有历史数据。MCP 实现遵循所用的 [stdio 传输](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)、[初始化](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle)和[工具协议](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)；它与 Paste 的本地服务具有不同授权和能力范围。
