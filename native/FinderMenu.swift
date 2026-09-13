import Cocoa

/// Shared by the settings catalog and Finder, so dynamically added templates,
/// destinations and applications use the same stable identifiers and defaults.
enum FinderMenu {
    private struct Entry {
        let id: String
        let title: String
        let standaloneTitle: String
        let request: [String:Any]
        let symbol: String?
        let needsSelection: Bool
        var enabled: Bool = true
    }
    private struct Group {
        let id: String
        let title: String
        let section: String
        let symbol: String
        let defaultLevel: Int
        var entries: [Entry]
        var enabled: Bool = true
        var isSubmenu: Bool {
            ["create","copy","move","favorites","open_app","convert","compress","tools"].contains(id)
        }
        var defaultGroupLevel: Int { isSubmenu && defaultLevel == 3 ? 2 : 0 }
        func level(in settings: [String:Any]) -> Int {
            guard isSubmenu else { return 0 }
            let override = (settings["menuGroupLevels"] as? [String:Int])?[id]
            return override.flatMap { (1...2).contains($0) ? $0 : nil } ?? defaultGroupLevel
        }
    }
    private static func groups(_ settings: [String:Any]) -> [Group] {
        let disabled = Set(settings["disabled"] as? [String] ?? [])
        let grouped = settings["groupMenus"] as? Bool ?? true
        func entry(_ id: String, _ title: String, _ command: String,
                   _ extra: [String:Any] = [:], standalone: String? = nil,
                   symbol: String? = nil, selection: Bool = true, enabled: Bool = true) -> Entry {
            var request = extra; request["cmd"] = command
            return Entry(id:id,title:title,standaloneTitle:standalone ?? title,request:request,
                         symbol:symbol,needsSelection:selection,enabled:enabled)
        }
        let formats = [("纯文本","txt"),("Markdown","md"),("Word 文档","docx"),("Excel 表格","xlsx"),("PowerPoint","pptx"),("富文本","rtf"),("XML","xml"),("JSON","json"),("HTML","html"),("Rust","rs"),("Python","py"),("Shell","sh"),("SVG","svg"),("Photoshop","psd"),("Illustrator (EPS)","ai")]
        var create = formats.map { title, format in
            entry("create:" + format,title,"create",["format":format],standalone:"新建 " + title,
                  symbol:"doc.badge.plus",selection:false,enabled:!disabled.contains("format:" + format))
        }
        for template in settings["templates"] as? [[String:Any]] ?? [] {
            guard let id = template["id"] as? String, !id.isEmpty else { continue }
            let name = template["name"] as? String ?? "模板"
            create.append(entry("template:" + id,name,"create",["template":id],standalone:"新建 " + name,
                                symbol:"doc.badge.plus",selection:false,enabled:template["enabled"] as? Bool != false))
        }
        create.append(entry("create_custom","自定义文件…","create_custom",standalone:"新建自定义文件…",selection:false))
        let favorites = settings["favorites"] as? [[String:Any]] ?? []
        func destinations(_ command: String) -> [Entry] {
            let prefix = command == "copy" ? "复制到 " : command == "move" ? "移动到 " : "打开目录 "
            var list = favorites.compactMap { favorite -> Entry? in
                guard let path = favorite["path"] as? String, !path.isEmpty else { return nil }
                let name = favorite["name"] as? String ?? URL(fileURLWithPath:path).lastPathComponent
                return entry(command + ":path:" + path,name,command,["destination":path],
                             standalone:prefix + name,symbol:"folder",selection:command != "favorite")
            }
            if command != "favorite" {
                list.append(entry(command + ":choose","其他目录…",command,standalone:prefix + "其他目录…",symbol:"folder"))
            }
            return list
        }
        let apps = settings["apps"] as? [[String:Any]] ?? [["name":"终端","id":"com.apple.Terminal"],["name":"iTerm2","id":"com.googlecode.iterm2"],["name":"VS Code","id":"com.microsoft.VSCode"]]
        let open = apps.compactMap { app -> Entry? in
            guard let id = app["id"] as? String, !id.isEmpty else { return nil }
            let name = app["name"] as? String ?? "应用"
            return entry("open_app:" + id,name,"open_app",["app":id],standalone:"在 " + name + " 中打开",symbol:"terminal",selection:false)
        }
        let images = [("PNG","png"),("JPG","jpg"),("WebP","webp"),("HEIC","heic"),("ICNS","icns"),("Mac 图标集","mac_icons"),("iOS 图标集","ios_icons")].map {
            entry("convert:" + $0.1,"转为 " + $0.0,"convert",["format":$0.1],symbol:"photo")
        }
        let toolDefs = [("拷贝路径","copy_path"),("拷贝名称","copy_name"),("快捷方式到桌面","shortcut"),("按文件名建文件夹","folder_from_name"),("解散文件夹","dissolve"),("重命名","rename"),("修复乱码文件名","repair_name"),("隐藏选中文件","hidden"),("取消隐藏","unhidden"),("显示隐藏文件","finder_show"),("不显示隐藏文件","finder_hide"),("隐藏扩展名","extension_hide"),("显示扩展名","extension_show"),("授予本人写入权限","writable"),("隔空投送","airdrop"),("设为墙纸","wallpaper"),("预览与标注","preview"),("图片置顶贴图","pin"),("交互式截图","screenshot"),("扫描目录空间","scan"),("移到废纸篓","trash"),("永久删除","delete")]
        let background = Set(["finder_show","finder_hide","screenshot","scan"])
        var all = [
            Group(id:"create",title:"新建文件",section:"新建文件",symbol:"doc.badge.plus",defaultLevel:3,entries:create),
            Group(id:"cut",title:"剪切",section:"文件工具",symbol:"scissors",defaultLevel:2,entries:[entry("cut","剪切","cut",symbol:"scissors")]),
            Group(id:"paste",title:"粘贴文件",section:"文件工具",symbol:"doc.on.clipboard",defaultLevel:2,entries:[entry("paste","粘贴文件","paste",symbol:"doc.on.clipboard",selection:false)]),
            Group(id:"copy",title:"复制文件到",section:"复制文件到",symbol:"doc.on.doc",defaultLevel:3,entries:destinations("copy")),
            Group(id:"move",title:"移动文件到",section:"移动文件到",symbol:"folder.badge.plus",defaultLevel:3,entries:destinations("move")),
            Group(id:"favorites",title:"常用目录",section:"常用目录",symbol:"star",defaultLevel:3,entries:destinations("favorite")),
            Group(id:"open_app",title:"在应用中打开",section:"在应用中打开",symbol:"terminal",defaultLevel:3,entries:open),
            Group(id:"info",title:"文件信息与校验值",section:"文件工具",symbol:"info.circle",defaultLevel:2,entries:[entry("info","文件信息与校验值","info",symbol:"info.circle")]),
            Group(id:"convert",title:"图片转换",section:"图片转换",symbol:"photo",defaultLevel:grouped ? 3 : 2,entries:images),
            Group(id:"compress",title:"压缩",section:"压缩",symbol:"archivebox",defaultLevel:3,entries:[entry("compress","压缩为 ZIP","compress"),entry("compress7z","压缩为 7z","compress7z"),entry("encrypt","加密压缩…","encrypt")]),
            Group(id:"extract",title:"解压归档",section:"压缩",symbol:"archivebox",defaultLevel:2,entries:[entry("extract","解压归档…","extract",symbol:"archivebox")]),
            Group(id:"icons",title:"设置文件图标",section:"文件工具",symbol:"paintpalette",defaultLevel:2,entries:[entry("icons","设置文件图标…","icons",symbol:"paintpalette")]),
            Group(id:"tools",title:"文件工具",section:"文件工具",symbol:"wrench.and.screwdriver",defaultLevel:grouped ? 3 : 2,entries:toolDefs.map { entry($0.1,$0.0,$0.1,selection:!background.contains($0.1)) }),
            Group(id:"workbench",title:"操作台入口",section:"应用",symbol:"cursorarrow.click",defaultLevel:2,entries:[entry("workbench","打开 RightClick 操作台","workbench",symbol:"cursorarrow.click",selection:false)])
        ]
        var seen = Set<String>()
        for index in all.indices {
            all[index].enabled = all[index].id == "workbench" || !disabled.contains("menu:" + all[index].id)
            all[index].entries = all[index].entries.filter { seen.insert($0.id).inserted }
        }
        let requested = settings["menuOrder"] as? [String] ?? []
        var order: [String] = []
        for key in requested + all.map({$0.id}) where !order.contains(key) { order.append(key) }
        return order.compactMap { key in all.first { $0.id == key } }
    }
    static func catalog(_ settings: [String:Any]) -> [String:Any] {
        ["groups":groups(settings).map { group -> [String:Any] in
            ["id":group.id,"title":group.title,"section":group.section,"enabled":group.enabled,
             "isSubmenu":group.isSubmenu,"defaultGroupLevel":group.defaultGroupLevel,
             "actions":group.entries.map { entry -> [String:Any] in
                ["id":entry.id,"title":entry.standaloneTitle,"menuTitle":entry.title,
                 "defaultLevel":group.defaultLevel,"enabled":entry.enabled]
             }]
        }]
    }
    static func build(_ settings: [String:Any], hasSelection: Bool, toolbar: Bool = false,
                      action: Selector, target: AnyObject, store: MenuActionStore) -> NSMenu {
        let root = NSMenu(title:"RightClick"); root.autoenablesItems = false
        let nested = toolbar ? root : NSMenu(title:"RightClick"); nested.autoenablesItems = false
        let levels = settings["menuLevels"] as? [String:Int] ?? [:]
        let icons = settings["showIcons"] as? Bool ?? true
        var sections: [String:NSMenu] = [:]
        for group in groups(settings) where group.enabled {
            let groupLevel = group.level(in:settings)
            for entry in group.entries where entry.enabled {
                let inheritedLevel = groupLevel > 0 ? groupLevel + 1 : group.defaultLevel
                let level = levels[entry.id].flatMap { (1...3).contains($0) ? $0 : nil } ?? inheritedLevel
                let inGroup = level == 3 || (level == 2 && groupLevel == 1)
                let item = NSMenuItem(title:inGroup ? entry.title : entry.standaloneTitle,action:action,keyEquivalent:"")
                item.target = target; item.isEnabled = !entry.needsSelection || hasSelection
                store.bind(item,request:entry.request)
                if icons, let symbol = entry.symbol { item.image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil) }
                if level == 1 { root.addItem(item) }
                else if !inGroup { nested.addItem(item) }
                else {
                    let parentMenu = level == 2 ? root : nested
                    let key = "\(toolbar ? 0 : level - 1):\(group.section)"
                    if sections[key] == nil {
                        let submenu = NSMenu(title:group.section); submenu.autoenablesItems = false
                        let parent = NSMenuItem(title:group.section,action:nil,keyEquivalent:""); parent.submenu = submenu
                        if icons { parent.image = NSImage(systemSymbolName:group.symbol,accessibilityDescription:nil) }
                        parentMenu.addItem(parent); sections[key] = submenu
                    }
                    sections[key]!.addItem(item)
                }
            }
        }
        if !toolbar && nested.numberOfItems > 0 {
            if root.numberOfItems > 0 { root.addItem(.separator()) }
            let parent = NSMenuItem(title:"RightClick",action:nil,keyEquivalent:""); parent.submenu = nested
            root.addItem(parent)
        }
        return root
    }
}
