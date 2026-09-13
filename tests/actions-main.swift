import Foundation

final class TestUI: FinderActionUI {
    var answers: [[String: String]?] = []
    var confirmations: [Bool] = []
    var choices: [String?] = []
    var prompts: [String] = []
    var results: [(String, String, [String])] = []
    func prompt(_ title: String, message: String, fields: [FinderField], accept: String) -> [String: String]? {
        prompts.append(title)
        return answers.isEmpty ? nil : answers.removeFirst()
    }
    func confirm(_ title: String, message: String, accept: String) -> Bool {
        prompts.append(title)
        return confirmations.isEmpty ? false : confirmations.removeFirst()
    }
    func choose(_ title: String, directory: Bool, initial: String) -> String? {
        prompts.append(title)
        return choices.isEmpty ? nil : choices.removeFirst()
    }
    func result(_ title: String, text: String, paths: [String]) { results.append((title,text,paths)) }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("rustclick-actions-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let binary = URL(fileURLWithPath:CommandLine.arguments[1])
let ui = TestUI()
var requests: [[String: Any]] = []
func engine(_ request: [String: Any]) throws -> [String: Any] {
    requests.append(request)
    // The OS adapter boundary is intercepted; all file/config/archive operations use the real Rust engine.
    if request["cmd"] as? String == "native" { return [:] }
    let process = Process(); process.executableURL = binary
    let data = try JSONSerialization.data(withJSONObject:request)
    process.arguments = ["--request", String(data:data, encoding:.utf8)!]
    var environment = ProcessInfo.processInfo.environment
    environment["RUSTCLICK_DATA_DIR"] = root.appendingPathComponent("config").path
    process.environment = environment
    let output = Pipe(); process.standardOutput = output
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    let result = try JSONSerialization.jsonObject(with:bytes) as! [String: Any]
    guard result["ok"] as? Bool == true else { throw FinderActionFailure(message:result["error"] as? String ?? "engine failed") }
    return result["data"] as? [String: Any] ?? [:]
}
let actions = FinderActions(execute:engine, ui:ui)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FinderActionFailure(message:message) }
    checks += 1
}
func request(_ cmd: String, _ extra: [String: Any] = [:]) -> [String: Any] {
    var value: [String: Any] = ["cmd":cmd,"dir":root.path,"paths":[root.appendingPathComponent("中文 文件.txt").path]]
    value.merge(extra) { _, new in new }; return value
}
func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath:root.appendingPathComponent(name).path) }
do {
    ui.answers = [["name":"中文 文件.txt"]]
    try actions.run(request("create",["format":"txt"]))
    try check(exists("中文 文件.txt"), "New file must be created from the compact name prompt")
    ui.answers = [nil]
    try actions.run(request("create",["format":"md"]))
    try check(!exists("未命名.md"), "Cancelling creation must not create a file")
    let destination = root.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
    let before = ui.prompts.count
    try actions.run(request("copy",["destination":destination.path]))
    try check(exists("destination/中文 文件.txt"), "Copy to favorite must use the destination, not the source directory")
    try check(ui.prompts.count == before, "Favorite destination must not require another prompt")
    ui.choices = [nil]
    let count = requests.count
    try actions.run(request("move"))
    try check(!requests.dropFirst(count).contains { $0["cmd"] as? String == "move" }, "Cancelled destination must not move files")
    ui.answers = [["name":"重命名.txt"]]
    try actions.run(request("rename"))
    try check(exists("重命名.txt") && !exists("中文 文件.txt"), "Rename must execute after accepting its name prompt")
    let renamed = [root.appendingPathComponent("重命名.txt").path]
    ui.confirmations = [false]
    try actions.run(request("delete",["paths":renamed,"confirmed":true]))
    try check(exists("重命名.txt"), "Incoming confirmed=true must not bypass the configured deletion confirmation")
    ui.confirmations = [true]
    try actions.run(request("delete",["paths":renamed]))
    try check(!exists("重命名.txt"), "Confirmed deletion must reach the existing protected Rust engine")
    let copied = [destination.appendingPathComponent("中文 文件.txt").path]
    try actions.run(request("info",["paths":copied]))
    try check(ui.results.last?.1.contains("SHA256") == true, "Checksums must appear in an independent result")
    try actions.run(request("scan",["dir":destination.path]))
    try check(ui.results.last?.1.contains("文件数：1") == true, "Scan must render the numeric file count")
    try actions.run(request("compress",["paths":copied]))
    let zip = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).first { $0.pathExtension == "zip" }!
    ui.answers = [["password":""]]
    try actions.run(request("extract",["paths":[zip.path]]))
    try check(requests.contains { $0["cmd"] as? String == "extract_auto" }, "Extraction must collect its password and call the correct engine command")
    try actions.run(request("cut",["paths":copied]))
    try actions.run(request("paste"))
    try check(exists("中文 文件.txt") && !exists("destination/中文 文件.txt"), "Cut/paste must work without web state")
    try actions.run(request("unhidden"))
    try check(requests.last?["cmd"] as? String == "hidden" && requests.last?["hidden"] as? Bool == false, "Unhide must translate the menu alias")
    try actions.run(request("open_app",["paths":[],"app":"com.microsoft.VSCode"]))
    let open = requests.last?["request"] as? [String: Any]
    try check(open?["paths"] as? [String] == [root.path], "Open app on background must use the targeted folder")
    try actions.run(request("favorite",["destination":destination.path]))
    let favorite = requests.last?["request"] as? [String: Any]
    try check(favorite?["cmd"] as? String == "open" && favorite?["paths"] as? [String] == [destination.path], "Favorite must open the destination directly")
    ui.answers = [["mode":"reset"]]
    try actions.run(request("icons"))
    try check((requests.last?["request"] as? [String:Any])?["reset"] as? Bool == true, "Icon reset must use native icon operation")
    ui.answers = [["mode":"image"]]; ui.choices = [nil]
    let iconStart = requests.count
    try actions.run(request("icons"))
    try check(!requests.dropFirst(iconStart).contains { $0["cmd"] as? String == "native" }, "Cancelling image selection must not change icons")
    ui.answers = [["encoding":"latin1"]]; ui.confirmations = [false]
    try Data().write(to:root.appendingPathComponent("repair.txt"))
    try actions.run(request("repair_name",["paths":[root.appendingPathComponent("repair.txt").path]]))
    try check(requests.last?["cmd"] as? String == "repair_preview", "Filename repair must stop at preview when declined")
    let promptCount = ui.prompts.count
    do {
        try actions.run(request("rename",["paths":[root.appendingPathComponent("中文 文件.txt").path,root.appendingPathComponent("repair.txt").path]]))
        throw FinderActionFailure(message:"Multi-selection rename must reject before asking for one name")
    } catch let error as FinderActionFailure {
        try check(error.message.contains("只选择一个") && ui.prompts.count == promptCount, "Multi-selection must not enter the single-file rename prompt")
    }
    let archiveStart = requests.count
    ui.answers = [nil]
    try actions.run(request("encrypt"))
    try check(!requests.dropFirst(archiveStart).contains { $0["cmd"] as? String == "archive7z" }, "Cancelling encryption must not create an archive")
    ui.answers = [["format":"7z","password":"test-only-password"]]
    try actions.run(request("encrypt"))
    let encrypted = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).first { $0.pathExtension == "7z" }!
    ui.answers = [["password":"test-only-password"]]
    try actions.run(request("extract",["paths":[encrypted.path]]))
    try check(exists("中文 文件.txt"), "Encrypted archive/extract flow must preserve the original")
    let qr = try engine(["cmd":"qr","text":"RustClick 测试","dir":root.path])
    ui.answers = [["format":"jpg"]]
    try actions.run(request("convert",["paths":qr["paths"]!]))
    let files = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
    try check(files.contains { $0.pathExtension == "jpg" }, "Format selection must drive a real image conversion")
    let imported = try engine(["cmd":"template_add","path":root.appendingPathComponent("repair.txt").path,"name":"测试模板"])
    ui.answers = [["name":"模板副本.txt"]]
    try actions.run(request("create",["template":imported["id"]!]))
    try check(exists("模板副本.txt"), "Custom template menus must retain their template identifier")
    let errorResults = ui.results.count
    let unreadable = root.appendingPathComponent("unreadable.txt")
    try Data("fixture".utf8).write(to:unreadable)
    try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:unreadable.path)
    try actions.run(request("copy",["paths":[root.appendingPathComponent("repair.txt").path,unreadable.path],"destination":destination.path]))
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:unreadable.path)
    try check(ui.results.count == errorResults + 1 && ui.results.last?.0.contains("部分项目未完成") == true, "Partial transfers must expose errors in an independent result")
    var config = try engine(["cmd":"state"])["config"] as! [String:Any]
    config["openAfterCreate"] = true; config["sound"] = true
    _ = try engine(["cmd":"save_config","config":config])
    ui.answers = [["name":"自动打开.txt"]]
    let createStart = requests.count
    try actions.run(request("create",["format":"txt"]))
    let nativeCommands = requests.dropFirst(createStart).compactMap { ($0["request"] as? [String:Any])?["cmd"] as? String }
    try check(nativeCommands == ["open","beep"], "Creation must honor existing open-after-create and sound preferences")
    do {
        try actions.run(request("unsupported"))
        throw FinderActionFailure(message:"Unknown actions must fail without opening the console")
    } catch let error as FinderActionFailure {
        try check(error.message.contains("未知"), "Unknown action should report an explicit error")
    }
    print("PASS: \(checks) Finder action checks with the real Rust engine")
} catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
