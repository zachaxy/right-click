# Input Source Pro 功能调研

调研日期：2026-11-12。依据官网、官方更新日志及官方仓库源码；未安装或进行实机测试。官网当前提供 2.14.0，更新日志日期为 2026-10-23；要求 macOS 12 或更新版本。[官网](https://inputsource.pro/zh-CN)、[更新日志](https://inputsource.pro/changelog)

## 产品定位

Input Source Pro 是管理 Mac 现有输入源的工具，核心是按应用或网站自动选择输入法，并在屏幕上提示当前输入状态。官方将其定义为免费、开源软件，采用 GPL-3.0 许可证；作者在 2.5.0-beta 公告中表示将对所有人保持免费，2.6.1 宣布开源。此次没有发现免费版／付费专业版的功能分层。[官方 README](https://github.com/runjuu/InputSourcePro#readme)、[免费与开源公告](https://inputsource.pro/changelog)

## 功能清单

以下例子是依据功能构造的使用场景，并非逐一实测结果。

| 功能 | 具体能力与例子 | 官方依据 |
| --- | --- | --- |
| 按应用自动切换 | 为不同应用指定默认输入法；例如聊天应用用中文、终端和编辑器用英文。官网还明确提到 Spotlight 类应用。 | [官网](https://inputsource.pro/zh-CN) |
| 全局默认与恢复策略 | 设置全局默认输入源；切回应用或网站时，可选择恢复上次使用的输入源，或使用默认输入源。 | [2.14.0 通用设置源码](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/UI/Screens/GeneralSettingsView.swift) |
| 按网站自动切换 | 同一浏览器中为不同网站使用不同输入法，例如 GitHub 用英文、中文社区用中文；更新日志另有地址栏规则的支持记录。 | [README](https://github.com/runjuu/InputSourcePro#readme)、[更新日志](https://inputsource.pro/changelog) |
| 临时输入状态提示 | 在切换应用、切换输入法、长按鼠标左键时显示当前输入法；增强模式还提供输入焦点变化时显示的选项。 | [官网](https://inputsource.pro/zh-CN)、[通用设置源码](https://github.com/runjuu/InputSourcePro/blob/main/Input%20Source%20Pro/UI/Screens/GeneralSettingsView.swift) |
| 常驻光标提示 | 可持续在鼠标附近显示输入法；能够取得文本光标位置时可跟随文本光标。额外光标支持需要增强模式和 Cursor Helper 设置。 | [2.12–2.13 更新说明](https://inputsource.pro/changelog) |
| 大小写锁定提示 | 可在输入法指示器中显示 Caps Lock 状态，并在大小写锁定状态变化时提示。 | [2.13.0 发布说明](https://github.com/runjuu/InputSourcePro/blob/main/docs/release-notes/2.13.0.md) |
| 指示器外观定制 | 可显示图标、名称或两者，有小／中／大三档；文字与背景颜色可全局设置或按输入法设置，并支持跟随系统深浅色。 | [信息样式](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/Utilities/Indicator/IndicatorInfo.swift)、[大小](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/Utilities/Indicator/IndicatorSize.swift)、[外观设置](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/UI/Screens/AppearanceSettingsView.swift)、[按输入法配色](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/UI/Components/KeyboardCustomization.swift) |
| 按应用使用英文标点 | 在指定应用强制使用受支持的英文符号，包括逗号、句号、分号、引号和方括号等，减少代码中混入中文／全角符号。不是任意字符的通用转换器。 | [README 的标点说明](https://github.com/runjuu/InputSourcePro#readme) |
| 自定义输入法快捷键 | 支持普通组合快捷键；左或右 Shift、Control、Option、Command 可单击／双击触发；Shift+Command 这样的多修饰键组合在当前 UI 中仅支持单次按压。同一快捷键可用于多个输入源之间切换。 | [快捷键设置源码](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/UI/Screens/KeyboardsSettingsView.swift)、[2.5、2.8、2.9 更新说明](https://inputsource.pro/changelog) |
| 按应用切换 F 键模式 | 为应用选择 F1–F12 标准功能键，或音量、亮度等媒体键；另支持快捷键手动切换及屏幕状态提示。 | [README](https://github.com/runjuu/InputSourcePro#readme)、[2.11 更新说明](https://inputsource.pro/changelog) |
| 设置备份与迁移 | 导出和导入 JSON 设置，包括应用／网站规则、颜色、快捷键组和已录制快捷键。导入界面会确认替换当前设置；不应等同于自动云同步。 | [设置界面](https://github.com/runjuu/InputSourcePro/blob/main/Input%20Source%20Pro/UI/Screens/GeneralSettingsView.swift)、[备份实现](https://github.com/runjuu/InputSourcePro/blob/main/Input%20Source%20Pro/Persistence/SettingsBackup.swift) |
| 自动化恢复配置 | 通过 `inputsourcepro://` URL Scheme 调用设置导入，可从命令行恢复备份并使用静默模式。此次未核实其具有通用外部自动化 API。 | [2.11 更新说明](https://inputsource.pro/changelog) |
| 运行与更新设置 | 开机启动、菜单栏图标显示开关、检查更新，以及可选测试版更新通道。 | [通用设置源码](https://github.com/runjuu/InputSourcePro/blob/main/Input%20Source%20Pro/UI/Screens/GeneralSettingsView.swift) |

## 浏览器覆盖

官网首页列出 Safari、Chrome、Edge、Firefox、Brave、Vivaldi、Arc；官方 README 还列出 Opera、Zen、Dia。更新日志又记录了 Thorium、Helium，以及 2.14.0 新增的 Comet、Aside、Whale（包括 Whale 分屏）。这些是不同官方页面确认的支持项，不应将首页较短的列表当作完整名单；各浏览器、系统版本的实际行为尚未实测。[官网](https://inputsource.pro/zh-CN)、[README](https://github.com/runjuu/InputSourcePro#readme)、[更新日志](https://inputsource.pro/changelog)

## 使用场景与边界

一个典型配置是：切入编辑器时使用英文，切入聊天应用时使用中文，浏览器按网站决定输入法，并在光标附近显示状态。这是规则驱动的自动切换；本次所查材料没有把它描述为依据正在输入的句子来自动判断语言的系统。[官网功能说明](https://inputsource.pro/zh-CN)

网站规则支持三种匹配：完整域名、域名及其子域名、网址正则表达式。可填写示例网址测试匹配，并为每条规则指定输入源、恢复策略及是否隐藏提示。浏览器地址栏可以单独设置默认输入源，该功能需要增强模式。[规则类型](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/Persistence/BrowserRule.swift)、[规则编辑界面](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/UI/Components/BrowserRuleEditView.swift)、[浏览器设置](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/UI/Screens/BrowserRulesSettingsView.swift)

提示位置可跟随鼠标、相对应用窗口或相对屏幕；后两种提供九个对齐位置及间距选项。优先靠近文本光标及常驻光标提示需要增强模式。[位置类型](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/Utilities/Indicator/IndicatorPosition.swift)、[位置设置](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/UI/Screens/PositionSettingsView.swift)

网站规则和增强模式需要辅助功能权限；修饰键快捷键需要辅助功能及输入监控权限，不应泛化成所有功能都需要输入监控。[浏览器权限提示](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/UI/Components/BrowserPermissionRequestView.swift)、[增强模式开关](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/UI/Components/EnhancedModeToggle.swift)、[快捷键设置](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/UI/Screens/KeyboardsSettingsView.swift)

不同应用能否提供文本光标位置会影响提示定位；官方为此提供额外光标支持，并持续修复兼容性问题。额外光标支持需要增强模式及 Cursor Helper，不能理解为任意应用都必定正常跟随光标。[2.13.0 发布说明](https://github.com/runjuu/InputSourcePro/blob/main/docs/release-notes/2.13.0.md)

Cursor Helper 是可选安装的辅助输入法组件；官方界面声明它只使用光标位置，不读取或记录文本。此处是转述该组件的声明，不是对整个软件的隐私审计结论。[组件说明](https://github.com/runjuu/InputSourcePro/blob/2.14.0/Input%20Source%20Pro/UI/Components/AdditionalCursorSupportView.swift)

主分支源码用于补充配置细节，不代表所有主分支改动都已经包含在官网下载包内。当前没有做安装、性能测试、第三方输入法逐项兼容测试或完整隐私审计。
