import Cocoa

let store = MenuActionStore()
final class Target: NSObject { @objc func performMenuAction(_ sender: NSMenuItem) {} }
let target = Target()
var checks = 0
func check(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n",stderr); exit(1) }
    checks += 1
}
func build(_ settings: [String:Any] = [:], selected: Bool = true, toolbar: Bool = false) -> NSMenu {
    store.reset()
    return FinderMenu.build(settings,hasSelection:selected,toolbar:toolbar,action:#selector(Target.performMenuAction(_:)),target:target,store:store)
}
func leaves(_ menu: NSMenu, ancestors: [String] = []) -> [(NSMenuItem,[String])] {
    menu.items.flatMap { item -> [(NSMenuItem,[String])] in
        if let submenu = item.submenu { return leaves(submenu,ancestors:ancestors + [item.title]) }
        return item.isSeparatorItem ? [] : [(item,ancestors)]
    }
}
func match(_ menu: NSMenu, _ cmd: String) -> [(NSMenuItem,[String])] {
    leaves(menu).filter { store.request(for:$0.0)?["cmd"] as? String == cmd }
}
let original = build()
check(match(original,"copy_path").first?.1 == ["RightClick","文件工具"],"Legacy menu must keep its original third-level placement")
let moved = build(["menuLevels":["copy_path":1,"copy_name":2,"cut":3,"create:md":1,"copy:path:/tmp/中文 目录":1],"favorites":[["name":"中文目录","path":"/tmp/中文 目录"]]])
check(match(moved,"copy_path").count == 1 && match(moved,"copy_path").first?.1 == [],"Promoted action must appear exactly once at the Finder root")
check(match(moved,"copy_name").first?.1 == ["RightClick"],"Second level must be directly under RightClick")
check(match(moved,"cut").first?.1 == ["RightClick","文件工具"],"A previously standalone item must support third-level placement")
let markdown = leaves(moved).first { store.request(for:$0.0)?["format"] as? String == "md" }
check(markdown?.0.title == "新建 Markdown" && markdown?.1 == [],"A root format action needs an unambiguous title")
let copy = match(moved,"copy").first { store.request(for:$0.0)?["destination"] as? String == "/tmp/中文 目录" }
check(copy?.1 == [] && copy?.0.title == "复制到 中文目录","Favorite promotions must keep their destination and clarify the action")
let copiedItem = NSMenuItem(title:copy!.0.title,action:nil,keyEquivalent:"")
copiedItem.tag = copy!.0.tag
check(store.request(for:copiedItem)?["destination"] as? String == "/tmp/中文 目录","Finder serialization must retain payload after relocation")
let empty = build(["menuLevels":["copy_path":1,"convert:png":1]],selected:false)
check(match(empty,"copy_path").first?.0.isEnabled == false,"Root actions requiring a selection must remain disabled on a folder background")
let disabled = build(["menuLevels":["copy_path":1,"create:md":1],"disabled":["menu:tools","format:md"]])
check(match(disabled,"copy_path").isEmpty,"Promotions must not bypass group visibility")
check(!leaves(disabled).contains { store.request(for:$0.0)?["format"] as? String == "md" },"Promotions must not bypass format visibility")
let compact = build(["groupMenus":false])
check(match(compact,"copy_path").first?.1 == ["RightClick"],"Existing ungrouped preference must remain the default")
let dynamic = build(["menuLevels":["template:sample":1,"open_app:dev.editor":2],"templates":[["id":"sample","name":"自定义模板","enabled":true]],"apps":[["id":"dev.editor","name":"编辑器"]]])
check(leaves(dynamic).first { store.request(for:$0.0)?["template"] as? String == "sample" }?.1 == [],"Custom templates must support root placement")
check(match(dynamic,"open_app").first?.1 == ["RightClick"],"Custom apps must support second-level placement")
let toolbar = build(["menuLevels":["copy_path":1,"copy_name":2,"cut":3]],toolbar:true)
check(match(toolbar,"copy_path").first?.1 == [] && match(toolbar,"copy_name").first?.1 == [],"Toolbar menu must not add a redundant RightClick wrapper")
let invalid = build(["menuLevels":["copy_path":99,"unknown":1]])
check(match(invalid,"copy_path").first?.1 == ["RightClick","文件工具"],"Invalid or stale values must fall back without creating unknown actions")
let catalog = FinderMenu.catalog(["apps":[["id":"dev.editor","name":"编辑器"]]])
let groups = catalog["groups"] as? [[String:Any]] ?? []
let entries = groups.flatMap { $0["actions"] as? [[String:Any]] ?? [] }
check(entries.contains { $0["id"] as? String == "open_app:dev.editor" },"Settings catalog and menu must share custom actions")
check(Set(entries.compactMap { $0["id"] as? String }).count == entries.count,"Catalog identifiers must be unique")
let rootGroup = build(["menuGroupLevels":["create":1]])
check(match(rootGroup,"create").allSatisfy { $0.1 == ["新建文件"] },"Moving the create group to root must keep its children inside it at level two")
check(rootGroup.items.contains { $0.title == "新建文件" && $0.submenu != nil },"Root must contain the group, not a flattened list of formats")
let onePromoted = build(["menuGroupLevels":["create":1],"menuLevels":["create:md":1]])
let promotedMD = leaves(onePromoted).filter { store.request(for:$0.0)?["format"] as? String == "md" }
check(promotedMD.count == 1 && promotedMD.first?.1 == [] && promotedMD.first?.0.title == "新建 Markdown","One child can move out of a root group without duplication")
check(leaves(onePromoted).first { store.request(for:$0.0)?["format"] as? String == "txt" }?.1 == ["新建文件"],"Promoting Markdown must leave sibling formats in the root group")
let inheritedTemplate = build(["menuGroupLevels":["create":1],"templates":[["id":"later","name":"新模板","enabled":true]]])
check(leaves(inheritedTemplate).first { store.request(for:$0.0)?["template"] as? String == "later" }?.1 == ["新建文件"],"New templates must inherit the group's position")
let groupBack = build(["menuGroupLevels":["create":2],"menuLevels":["create:md":1]])
check(leaves(groupBack).first { store.request(for:$0.0)?["format"] as? String == "txt" }?.1 == ["RightClick","新建文件"],"A second-level group must put default children at level three")
check(leaves(groupBack).first { store.request(for:$0.0)?["format"] as? String == "md" }?.1 == [],"Moving a group must preserve independently promoted children")
let explicitSecond = build(["menuGroupLevels":["create":1],"menuLevels":["create:md":2,"create:txt":3]])
check(leaves(explicitSecond).first { store.request(for:$0.0)?["format"] as? String == "md" }?.1 == ["新建文件"],"A second-level child belongs to its root group")
check(leaves(explicitSecond).first { store.request(for:$0.0)?["format"] as? String == "txt" }?.1 == ["RightClick","新建文件"],"Explicit third-level placement must remain available")
let groupHidden = build(["menuGroupLevels":["create":1],"menuLevels":["create:md":1],"disabled":["menu:create"]])
check(match(groupHidden,"create").isEmpty && !groupHidden.items.contains { $0.title == "新建文件" },"Hidden groups must hide inherited and promoted children")
let noChildren = build(["menuGroupLevels":["favorites":1],"menuLevels":["favorite:path:/tmp":1],"favorites":[["name":"临时","path":"/tmp"]]])
check(!noChildren.items.contains { $0.title == "常用目录" },"A group with every child promoted must not leave an empty submenu")
let groupToolbar = build(["menuGroupLevels":["create":1],"menuLevels":["create:md":3]],toolbar:true)
check(groupToolbar.items.filter { $0.title == "新建文件" }.count == 1 && match(groupToolbar,"create").allSatisfy { $0.1 == ["新建文件"] },"Toolbar must merge the same group without duplicate submenus")
check(groups.first { $0["id"] as? String == "create" }?["isSubmenu"] as? Bool == true,"Catalog must distinguish actual submenus from standalone actions")
check(groups.first { $0["id"] as? String == "create" }?["defaultGroupLevel"] as? Int == 2,"Catalog must expose the default position of the group itself")
print("PASS: \(checks) Finder menu placement checks")
