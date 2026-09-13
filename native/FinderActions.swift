import Foundation

struct FinderField {
    let key: String
    let label: String
    var value = ""
    var choices: [(String, String)] = []
    var secure = false
    var required = true
}

protocol FinderActionUI: AnyObject {
    func prompt(_ title: String, message: String, fields: [FinderField], accept: String) -> [String: String]?
    func confirm(_ title: String, message: String, accept: String) -> Bool
    func choose(_ title: String, directory: Bool, initial: String) -> String?
    func result(_ title: String, text: String, paths: [String])
}

struct FinderActionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class FinderActions {
    let execute: ([String: Any]) throws -> [String: Any]
    let ui: FinderActionUI
    init(execute: @escaping ([String: Any]) throws -> [String: Any], ui: FinderActionUI) {
        self.execute = execute
        self.ui = ui
    }

    @discardableResult func run(_ request: [String: Any]) throws -> String? {
        let command = request["cmd"] as? String ?? ""
        let state = try execute(["cmd":"state"])
        let config = state["config"] as? [String:Any] ?? [:]
        let home = state["home"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.path
        let directory = request["dir"] as? String ?? home + "/Desktop"
        let paths = request["paths"] as? [String] ?? []
        func requireFiles() throws {
            if paths.isEmpty { throw FinderActionFailure(message:"请先在访达中选择文件或文件夹") }
        }
        func native(_ cmd: String, _ values: [String:Any] = [:]) throws -> [String:Any] {
            var payload = values; payload["cmd"] = cmd
            return try execute(["cmd":"native", "request":payload])
        }
        func operation(_ cmd: String, _ values: [String:Any] = [:]) throws -> [String:Any] {
            var payload: [String:Any] = ["cmd":cmd,"paths":paths,"dir":directory]
            payload.merge(values) { _, new in new }
            return try execute(payload)
        }
        func finish(_ data: [String:Any], _ title: String) -> String? {
            let errors = data["errors"] as? [[String:Any]] ?? []
            if !errors.isEmpty {
                let completed = (data["paths"] as? [String] ?? []).count
                ui.result(title + "：部分项目未完成", text:"已完成 \(completed) 项\n\n" + errors.map {
                    "\($0["source"] as? String ?? "")\n\($0["error"] as? String ?? "操作失败")"
                }.joined(separator:"\n\n"), paths:data["paths"] as? [String] ?? [])
                return nil
            }
            return data["message"] as? String ?? title + "完成"
        }
        switch command {
        case "copy_path", "copy_name":
            _ = try operation(command)
            return nil
        case "create", "create_custom":
            let templateID = request["template"] as? String
            let template = (config["templates"] as? [[String:Any]] ?? []).first { $0["id"] as? String == templateID }
            if templateID != nil && template == nil { throw FinderActionFailure(message:"模板不存在，请重新打开右键菜单") }
            var format = request["format"] as? String ?? (command == "create_custom" ? "custom" : "txt")
            if command == "create" && request["format"] == nil && templateID == nil {
                let formats = (state["formats"] as? [[String:Any]] ?? []).compactMap { f -> (String,String)? in
                    guard let id = f["id"] as? String, let name = f["name"] as? String else { return nil }
                    return (id,name)
                }
                guard let answer = ui.prompt("新建文件",message:"选择文件类型",fields:[FinderField(key:"format",label:"文件类型",value:"txt",choices:formats)],accept:"继续") else { return nil }
                format = answer["format"] ?? "txt"
            }
            let ext = template?["ext"] as? String ?? (format == "custom" ? "txt" : format)
            guard let answer = ui.prompt("新建文件",message:"保存到：\(directory)",fields:[FinderField(key:"name",label:"文件名",value:"未命名." + ext)],accept:"创建") else { return nil }
            var options: [String:Any] = ["name":answer["name"] ?? "", "format":format]
            if let id = templateID { options["template"] = id }
            let result = try operation("create",options)
            if config["openAfterCreate"] as? Bool == true { _ = try native("open",["paths":result["paths"] ?? []]) }
            if config["sound"] as? Bool == true { _ = try native("beep") }
            return finish(result,"新建文件")
        case "copy", "move":
            try requireFiles()
            let preset = request["destination"] as? String ?? ""
            guard let destination = preset.isEmpty ? ui.choose(command == "copy" ? "复制到目录" : "移动到目录",directory:true,initial:directory) : preset else { return nil }
            return finish(try operation(command,["dir":destination]),command == "copy" ? "复制" : "移动")
        case "favorite":
            guard let destination = request["destination"] as? String, !destination.isEmpty else { throw FinderActionFailure(message:"常用目录已失效，请重新打开菜单") }
            _ = try native("open",["paths":[destination]])
            return nil
        case "open_app":
            _ = try native("open_app",["paths":paths.isEmpty ? [directory] : paths,"app":request["app"] as? String ?? "com.apple.Terminal","tab":config["terminalTab"] as? Bool ?? false])
            return nil
        case "cut", "paste", "cancel_cut", "folder_from_name", "writable":
            let labels = ["cut":"剪切","paste":"粘贴","cancel_cut":"取消剪切","folder_from_name":"按文件名建文件夹","writable":"权限设置"]
            return finish(try operation(command),labels[command]!)
        case "shortcut":
            return finish(try operation(command,["dir":home + "/Desktop"]),"创建快捷方式")
        case "hidden", "unhidden":
            return finish(try operation("hidden",["hidden":command == "hidden"]),command == "hidden" ? "隐藏文件" : "取消隐藏")
        case "extension_hide", "extension_show":
            try requireFiles()
            return finish(try native("extension_hidden",["paths":paths,"hidden":command == "extension_hide"]),"扩展名设置")
        case "finder_show", "finder_hide":
            let result = try native("finder_hidden",["show":command == "finder_show"])
            ui.result("访达显示设置",text:result["message"] as? String ?? "设置已保存",paths:[])
            return nil
        case "rename":
            try requireFiles()
            guard paths.count == 1 else { throw FinderActionFailure(message:"重命名请只选择一个文件") }
            guard let answer = ui.prompt("重命名文件",message:URL(fileURLWithPath:paths[0]).deletingLastPathComponent().path,fields:[FinderField(key:"name",label:"新名称",value:URL(fileURLWithPath:paths[0]).lastPathComponent)],accept:"重命名") else { return nil }
            return finish(try operation("rename",["name":answer["name"] ?? ""]),"重命名")
        case "delete", "dissolve":
            try requireFiles()
            if command == "dissolve" || config["confirmDelete"] as? Bool != false {
                let title = command == "delete" ? "永久删除这些文件？" : "解散所选文件夹？"
                let message = command == "delete" ? "此操作跳过废纸篓，无法撤销。" : "将内容移到上一级目录，再移除空文件夹；同名项目会另存。"
                guard ui.confirm(title,message:message + "\n\n" + paths.joined(separator:"\n"),accept:command == "delete" ? "永久删除" : "解散") else { return nil }
            }
            return finish(try operation(command,["confirmed":true]),command == "delete" ? "删除" : "解散文件夹")
        case "repair_name":
            try requireFiles()
            guard let answer = ui.prompt("修复乱码文件名",message:"先预览名称转换，再选择是否应用。不会修改文件内容。",fields:[FinderField(key:"encoding",label:"原始字节编码",value:"gbk",choices:[("gbk","GBK → UTF-8"),("big5","Big5 → UTF-8"),("latin1","Latin-1 → UTF-8")])],accept:"预览") else { return nil }
            let encoding = answer["encoding"] ?? "gbk"
            let preview = try operation("repair_preview",["encoding":encoding])
            let names = preview["names"] as? [[String:Any]] ?? []
            let message = names.map { "\($0["old"] as? String ?? "") → \($0["new"] as? String ?? "")" }.joined(separator:"\n")
            guard ui.confirm("确认文件名修复",message:message,accept:"应用") else { return nil }
            return finish(try operation("repair_apply",["encoding":encoding]),"文件名修复")
        case "info", "scan":
            let result = try operation(command)
            var lines: [String] = []
            if command == "info" {
                for file in result["files"] as? [[String:Any]] ?? [] {
                    lines.append(file["path"] as? String ?? "")
                    for (key,label) in [("bytes","字节数"),("permissions","权限"),("md5","MD5"),("sha1","SHA1"),("sha256","SHA256"),("sha512","SHA512")] {
                        if let value = file[key] { lines.append("\(label)：\(value)") }
                    }
                    lines.append("")
                }
            } else {
                lines = [directory,"总字节数：\(result["bytes"] ?? 0)","文件数：\(result["files"] ?? 0)","无法读取：\(result["unreadable"] ?? 0)","","占用最大的文件："]
                for file in result["largest"] as? [[String:Any]] ?? [] { lines.append("\(file["bytes"] ?? 0) 字节  \(file["path"] ?? "")") }
            }
            ui.result(command == "info" ? "文件信息与校验值" : "目录空间",text:lines.joined(separator:"\n"),paths:command == "info" ? paths : [directory])
            return nil
        case "convert":
            try requireFiles()
            var format = request["format"] as? String
            if format == nil {
                let formats = [("png","PNG"),("jpg","JPG"),("webp","WebP"),("heic","HEIC"),("icns","ICNS"),("mac_icons","Mac 图标集"),("ios_icons","iOS 图标集")]
                guard let answer = ui.prompt("图片转换",message:"生成新文件，保留原图。",fields:[FinderField(key:"format",label:"输出格式",value:"png",choices:formats)],accept:"转换") else { return nil }
                format = answer["format"] ?? "png"
            }
            return finish(try operation("convert",["format":format!]),"图片转换")
        case "compress", "compress7z", "encrypt", "extract":
            try requireFiles()
            if command == "compress" { return finish(try operation("compress",["format":"zip"]),"压缩") }
            if command == "compress7z" { return finish(try operation("archive7z",["format":"7z"]),"压缩") }
            let isExtract = command == "extract"
            var fields = [FinderField(key:"password",label:isExtract ? "密码（未加密可留空）" : "密码",secure:true,required:!isExtract)]
            if !isExtract { fields.insert(FinderField(key:"format",label:"归档格式",value:"7z",choices:[("7z","7z (AES-256)"),("zip","ZIP (AES-256)")]),at:0) }
            guard let answer = ui.prompt(isExtract ? "解压归档" : "加密压缩",message:isExtract ? "每个归档会解压到新的独立文件夹。" : "密码仅用于本次压缩，不保存到设置。",fields:fields,accept:isExtract ? "解压" : "压缩") else { return nil }
            if !isExtract && (answer["password"] ?? "").isEmpty { throw FinderActionFailure(message:"加密压缩密码不能为空") }
            return finish(try operation(isExtract ? "extract_auto" : "archive7z",["password":answer["password"] ?? "","format":answer["format"] ?? "7z"]),isExtract ? "解压" : "压缩")
        case "icons":
            try requireFiles()
            let modes = [("A087DF","薰衣草"),("7298D5","雾蓝"),("78B697","薄荷"),("D9A16E","杏橙"),("D9868C","珊瑚"),("8992A0","石墨"),("image","使用自己的图片…"),("reset","恢复默认图标")]
            guard let answer = ui.prompt("设置文件图标",message:"应用于所选的 \(paths.count) 个项目。",fields:[FinderField(key:"mode",label:"图标",value:"A087DF",choices:modes)],accept:"应用") else { return nil }
            let mode = answer["mode"] ?? "A087DF"
            var values: [String:Any] = ["paths":paths]
            if mode == "image" {
                guard let image = ui.choose("选择图标图片",directory:false,initial:directory) else { return nil }
                values["image"] = image
            } else if mode == "reset" { values["reset"] = true }
            else { values["color"] = mode }
            return finish(try native("icon",values),"图标设置")
        case "preview", "pin", "airdrop", "wallpaper", "trash", "open_default", "reset_icon":
            try requireFiles()
            let mapped = command == "open_default" ? "open" : command == "reset_icon" ? "icon" : command
            let result = try native(mapped,["paths":paths,"reset":command == "reset_icon"])
            return ["wallpaper","trash","reset_icon"].contains(command) ? finish(result,["wallpaper":"设置墙纸","trash":"移到废纸篓","reset_icon":"恢复图标"][command]!) : nil
        case "screenshot":
            _ = try native("screenshot",["dir":directory])
            return nil
        case "text":
            let value = request["text"] as? String ?? ""
            if let provider = request["provider"] as? String {
                _ = try native("translate",["provider":provider,"text":value])
                return nil
            }
            guard let answer = ui.prompt("生成二维码",message:"二维码在本机生成。",fields:[FinderField(key:"text",label:"文字或链接",value:value)],accept:"生成") else { return nil }
            guard let destination = ui.choose("保存二维码到目录",directory:true,initial:directory) else { return nil }
            let result = try operation("qr",["text":answer["text"] ?? "","dir":destination])
            ui.result("二维码已生成",text:(result["paths"] as? [String] ?? []).joined(separator:"\n"),paths:result["paths"] as? [String] ?? [])
            return nil
        default: throw FinderActionFailure(message:"未知右键操作：\(command)")
        }
    }
}
