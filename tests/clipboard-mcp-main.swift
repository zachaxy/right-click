import Cocoa

if CommandLine.arguments.contains("--stdio") {
    runClipboardMCP()
    exit(0)
}

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); failures += 1 }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-mcp-\(UUID().uuidString)")
let directory = root.appendingPathComponent("clipboard")
defer { try? FileManager.default.removeItem(at: root) }
let store = ClipboardStore(directory: directory)
let board = try store.addPinboard(name: "项目\n资料")
let pinned = try store.addText("保留的资料\n\"jsonrpc\":\"2.0\"", title: "中文收藏", pinboardID: board.id)
let privateItem = try store.addText("不在收藏夹中的私密历史")
let long = try store.addText(String(repeating: "长", count: 18000), pinboardID: board.id)
let image = try store.addText("OCR fixture", pinboardID: board.id)
let copiedFile = try store.addText(root.appendingPathComponent("copied-secret.txt").path, pinboardID: board.id)
try "FILE_CONTENT_MUST_NOT_BE_READ".write(to: root.appendingPathComponent("copied-secret.txt"), atomically: true, encoding: .utf8)

// The fixture stores OCR as a normal persisted field; no image recognition or user pasteboard is needed.
let index = directory.appendingPathComponent("state.json")
var fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! [String: Any]
var fixtureEntries = fixture["entries"] as! [[String: Any]]
for i in fixtureEntries.indices {
    if fixtureEntries[i]["id"] as? String == image.id {
        fixtureEntries[i]["text"] = ""
        fixtureEntries[i]["kind"] = "image"
        fixtureEntries[i]["ocrText"] = "截图中识别的中文合同"
    }
    if fixtureEntries[i]["id"] as? String == copiedFile.id { fixtureEntries[i]["kind"] = "files" }
}
fixture["entries"] = fixtureEntries
try JSONSerialization.data(withJSONObject: fixture).write(to: index, options: .atomic)

func request(_ server: ClipboardMCPServer, _ method: String, _ params: [String: Any] = [:], id: Any = 1) -> [String: Any] {
    let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    guard let response = server.handle(data), let result = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
        check(false, "Request must return a JSON object")
        return [:]
    }
    check(!response.contains(10), "Protocol responses must occupy exactly one line")
    return result
}

func errorCode(_ result: [String: Any]) -> Int? { (result["error"] as? [String: Any])?["code"] as? Int }

func initialize(_ server: ClipboardMCPServer, version: String = "2025-06-18") -> [String: Any] {
    let response = request(server, "initialize", ["protocolVersion": version, "capabilities": [:] as [String: Any], "clientInfo": ["name": "test", "version": "1"]])
    check(server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil, "Initialized notification has no response")
    return response["result"] as? [String: Any] ?? [:]
}

func tool(_ server: ClipboardMCPServer, _ name: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
    request(server, "tools/call", ["name": name, "arguments": arguments])
}

func payload(_ response: [String: Any]) -> [String: Any] {
    let result = response["result"] as? [String: Any] ?? [:]
    let content = result["content"] as? [[String: Any]] ?? []
    guard let text = content.first?["text"] as? String,
          let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
    return parsed
}

func isToolError(_ response: [String: Any]) -> Bool {
    (response["result"] as? [String: Any])?["isError"] as? Bool == true
}

func settings(_ change: (inout ClipboardSettings) -> Void) throws {
    let current = ClipboardStore(directory: directory)
    var value = current.settings
    change(&value)
    try current.updateSettings(value)
}

let server = ClipboardMCPServer(directory: directory)
check(errorCode(request(server, "tools/list")) == -32002, "Tools require completed initialization")
check(request(server, "ping")["result"] is [String: Any], "Ping works before initialization")
check(initialize(server)["protocolVersion"] as? String == "2025-06-18", "Negotiate the current protocol")
for version in ["2024-11-05", "2025-03-26"] {
    check(initialize(ClipboardMCPServer(directory: directory), version: version)["protocolVersion"] as? String == version, "Negotiate supported older protocols")
}
check(initialize(ClipboardMCPServer(directory: directory), version: "unknown-version")["protocolVersion"] as? String == "2025-06-18", "Unknown versions negotiate the supported current version")
check(errorCode(request(server, "missing/method")) == -32601, "Unknown methods return Method not found")
check(errorCode(request(server, "ping", id: true)) == -32600, "Boolean request IDs are invalid")
check(request(server, "ping", id: "string-id")["id"] as? String == "string-id", "String IDs round-trip")
check(server.handle(Data(#"{"jsonrpc":"2.0","method":"unknown/notification"}"#.utf8)) == nil, "Unknown notifications have no response")
check(server.handle(Data(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"clipboard_search"}}"#.utf8)) == nil, "Tool notifications cannot produce content")
let malformed = server.handle(Data("{".utf8))!
check((try JSONSerialization.jsonObject(with: malformed) as! [String: Any])["error"] != nil, "Malformed JSON yields a parse error")
let batch = server.handle(Data("[]".utf8))!
check(errorCode(try JSONSerialization.jsonObject(with: batch) as! [String: Any]) == -32600, "Batches are rejected without executing tool calls")
let oversized = server.handle(Data(repeating: 32, count: ClipboardMCPServer.maximumRequestBytes + 1))!
check(errorCode(try JSONSerialization.jsonObject(with: oversized) as! [String: Any]) == -32700, "Oversized requests are rejected")

let definitions = (request(server, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
check(Set(definitions.compactMap { $0["name"] as? String }) == Set(["clipboard_search", "clipboard_get", "clipboard_pinboards"]), "Only read-only tools are exposed")
for name in ["clipboard_search", "clipboard_pinboards"] {
    check(isToolError(tool(server, name)), "Disabled MCP must block \(name), including metadata")
}
check(isToolError(tool(server, "clipboard_get", ["id": pinned.id])), "Disabled MCP blocks direct reads")

try settings { $0.mcpEnabled = true }
let allowed = payload(tool(server, "clipboard_search"))
let items = allowed["items"] as? [[String: Any]] ?? []
check(allowed["scope"] as? String == "pinboards_only", "Default authorization scope is pinboards only")
check(items.count == 4 && !items.contains(where: { $0["id"] as? String == privateItem.id }), "Unpinned history must not leak through search")
check(isToolError(tool(server, "clipboard_get", ["id": privateItem.id])), "Known unpinned UUID is still unauthorized")
check((payload(tool(server, "clipboard_get", ["id": pinned.id]))["item"] as? [String: Any])?["text"] as? String == pinned.text, "Chinese, quotes and embedded newlines round-trip as data")
let longItem = payload(tool(server, "clipboard_get", ["id": long.id]))["item"] as? [String: Any] ?? [:]
check((longItem["text"] as? String)?.count == 16000 && longItem["truncated"] as? Bool == true, "Large content is truncated with an explicit indicator")
let recognized = payload(tool(server, "clipboard_search", ["query": "中文合同", "kind": "image"]))["items"] as? [[String: Any]] ?? []
check(recognized.count == 1 && recognized.first?["id"] as? String == image.id, "Search includes persisted OCR and respects kind filters")
let fileResponse = tool(server, "clipboard_get", ["id": copiedFile.id])
check(!String(decoding: try JSONSerialization.data(withJSONObject: fileResponse), as: UTF8.self).contains("FILE_CONTENT_MUST_NOT_BE_READ"), "Copied file targets are never opened")
let boards = payload(tool(server, "clipboard_pinboards"))["pinboards"] as? [[String: Any]] ?? []
check(boards.first?["itemCount"] as? Int == 4 && boards.first?["name"] as? String == board.name, "Pinboard listing returns scoped counts and escaped names")

let pageOne = payload(tool(server, "clipboard_search", ["limit": 2]))
let cursor = pageOne["nextCursor"] as? String ?? ""
let pageTwo = payload(tool(server, "clipboard_search", ["limit": 2, "cursor": cursor]))
let firstIDs = Set((pageOne["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
let secondIDs = Set((pageTwo["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
check(firstIDs.count == 2 && secondIDs.count == 2 && firstIDs.isDisjoint(with: secondIDs), "Pagination returns each entry once for an unchanged index")
for args: [String: Any] in [["limit": 51], ["limit": true], ["limit": 1.5], ["cursor": "-1"], ["since": "yesterday"], ["kind": "unknown"], ["path": "/etc/passwd"]] {
    check(errorCode(tool(server, "clipboard_search", args)) == -32602, "Reject invalid or unknown tool arguments")
}
check(errorCode(tool(server, "clipboard_get", ["id": "../../state.json"])) == -32602, "Item IDs cannot be paths")
check(errorCode(tool(server, "clipboard_write")) == -32602, "No write tool can be called")

try settings { $0.mcpIncludeHistory = true }
check(!isToolError(tool(server, "clipboard_get", ["id": privateItem.id])), "Explicit history authorization takes effect without restarting the MCP process")
try settings { $0.mcpIncludeHistory = false }
check(isToolError(tool(server, "clipboard_get", ["id": privateItem.id])), "Revoking history authorization is observed on the next request")
try settings { $0.mcpEnabled = false }
check(isToolError(tool(server, "clipboard_get", ["id": pinned.id])), "Revoking MCP access blocks previously readable pinned entries")

// Exercise the real stdio entry point in a separate process with an isolated data directory.
let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.arguments = ["--stdio"]
var environment = ProcessInfo.processInfo.environment
environment["RUSTCLICK_DATA_DIR"] = root.path
child.environment = environment
let input = Pipe(), output = Pipe(), errors = Pipe()
child.standardInput = input; child.standardOutput = output; child.standardError = errors
try child.run()
let lines: [[String: Any]] = [
    ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any], "clientInfo": ["name": "stdio-test", "version": "1"]]],
    ["jsonrpc": "2.0", "method": "notifications/initialized"],
    ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "clipboard_search"]],
    ["jsonrpc": "2.0", "id": 3, "method": "ping"]
]
for line in lines {
    input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: line))
    input.fileHandleForWriting.write(Data([10]))
}
try input.fileHandleForWriting.close()
let rawOutput = output.fileHandleForReading.readDataToEndOfFile()
child.waitUntilExit()
let responseLines = rawOutput.split(separator: 10)
check(child.terminationStatus == 0 && responseLines.count == 3, "Real stdio transport emits only request responses and exits at EOF")
let responses = try responseLines.map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
check(responses.compactMap { $0["id"] as? Int } == [1, 2, 3], "Stdio response IDs preserve ordering")
check(isToolError(responses[1]), "Stdio subprocess obeys the persisted disabled setting")

let original = try Data(contentsOf: index)
try Data("broken storage".utf8).write(to: index, options: .atomic)
check(isToolError(tool(server, "clipboard_search")), "Unreadable state fails closed")
check(try Data(contentsOf: index) == Data("broken storage".utf8), "Read-only MCP never overwrites unreadable state")
try original.write(to: index, options: .atomic)
if failures > 0 { exit(1) }
print("PASS: MCP lifecycle, scope, revocation, bounded data, validation, OCR, file isolation and stdio transport")
