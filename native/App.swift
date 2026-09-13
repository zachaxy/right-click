import Cocoa
import WebKit
import FinderSync
import ServiceManagement
import ImageIO

private var backend: (@convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?)!
private var releaseBackend: (@convention(c) (UnsafeMutablePointer<CChar>?) -> Void)!
private let worker = DispatchQueue(label: "dev.rustclick.engine", qos: .userInitiated)
private var controller: AppController!
func encode(_ v: Any) -> String { String(data: (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed,.sortedKeys])) ?? Data("{}".utf8), encoding: .utf8)! }
func decode(_ s:String) -> [String:Any] { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String:Any] ?? [:] }
func engine(_ v:[String:Any])->[String:Any] { let p=encode(v).withCString { backend($0) }; guard let p=p else{return ["ok":false,"error":"Rust engine unavailable"]};let text=String(cString:p);releaseBackend(p);return decode(text) }
func apple(_ source:String)throws->NSAppleEventDescriptor {var error:NSDictionary?;let result=NSAppleScript(source:source)!.executeAndReturnError(&error);if let error=error{throw NSError(domain:"RightClick",code:1,userInfo:[NSLocalizedDescriptionKey:error.description])};return result}
func appleString(_ text:String)->String { "\"" + text.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:"\r",with:"\\r") + "\"" }
func shellQuote(_ s:String)->String {"'"+s.replacingOccurrences(of:"'",with:"'\\''")+"'"}
func nativeWork(_ req:[String:Any])throws->[String:Any] {
    let cmd=req["cmd"] as? String ?? ""
    let paths=(req["paths"] as? [String] ?? []).map{URL(fileURLWithPath:$0)}
    switch cmd {
    case "choose":
        let panel=NSOpenPanel();panel.canChooseFiles=req["kind"] as? String != "directory";panel.canChooseDirectories=true;panel.allowsMultipleSelection=req["multiple"] as? Bool ?? false;panel.prompt="选择";panel.message=req["message"] as? String ?? "选择要使用的文件或目录";NSApp.activate(ignoringOtherApps:true);return ["paths":panel.runModal() == .OK ? panel.urls.map{$0.path}:[]]
    case "clipboard": NSPasteboard.general.clearContents();NSPasteboard.general.setString(req["text"] as? String ?? "",forType:.string);return ["copied":true]
    case "clipboard_image": guard let url=paths.first,let img=NSImage(contentsOf:url)else{throw failure("图片无法读取")};NSPasteboard.general.clearContents();NSPasteboard.general.writeObjects([img]);return ["copied":true]
    case "open": for p in paths { if !NSWorkspace.shared.open(p){throw failure("无法打开 \(p.path)")} };return ["opened":paths.count]
    case "reveal": NSWorkspace.shared.activateFileViewerSelecting(paths);return [:]
    case "open_app":
        let id=req["app"] as? String ?? "com.apple.Terminal";let tab=req["tab"] as? Bool ?? false
        if id=="com.apple.Terminal" || id=="com.googlecode.iterm2" {
            let url=paths.first ?? FileManager.default.homeDirectoryForCurrentUser;var isDir:ObjCBool=false;FileManager.default.fileExists(atPath:url.path,isDirectory:&isDir);let dir=isDir.boolValue ? url.path:url.deletingLastPathComponent().path;let command="cd -- " + shellQuote(dir)
            if id=="com.apple.Terminal" {
                if tab { _ = try apple("tell application \"Terminal\"\nactivate\nif (count of windows) = 0 then do script \"\"\nend tell\ntell application \"System Events\" to tell process \"Terminal\" to keystroke \"t\" using command down\ntell application \"Terminal\" to do script \(appleString(command)) in selected tab of front window") }
                else { _ = try apple("tell application \"Terminal\"\nactivate\ndo script \(appleString(command))\nend tell") }
            }else{_ = try apple("tell application \"iTerm\"\nactivate\nif (count of windows) = 0 then create window with default profile\n\(tab ? "tell current window to create tab with default profile":"create window with default profile")\ntell current session of current window to write text \(appleString(command))\nend tell")};return [:]
        }
        guard let app=NSWorkspace.shared.urlForApplication(withBundleIdentifier:id) ?? (id.hasSuffix(".app") ? URL(fileURLWithPath:id):nil) else {throw failure("未安装此应用，请在「开发工具」中选择一个已安装的应用")};NSWorkspace.shared.open(paths,withApplicationAt:app,configuration:NSWorkspace.OpenConfiguration());return [:]
    case "app_info":let p=paths.first ?? URL(fileURLWithPath:"");guard let bundle=Bundle(url:p)else{throw failure("请选择 .app 应用")};return ["id":bundle.bundleIdentifier ?? p.path,"name":bundle.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? p.deletingPathExtension().lastPathComponent]
    case "apps":return ["apps":(req["apps"] as? [[String:Any]] ?? []).map{ app->[String:Any] in var a=app;let id=app["id"] as? String ?? "";a["installed"]=NSWorkspace.shared.urlForApplication(withBundleIdentifier:id) != nil || FileManager.default.fileExists(atPath:id);return a}]
    case "trash":for p in paths{try FileManager.default.trashItem(at:p,resultingItemURL:nil)};return [:]
    case "beep":NSSound.beep();return [:]
    case "icon":
        let reset=req["reset"] as? Bool ?? false
        var icon:NSImage?=nil
        if !reset {if let source=req["image"] as? String {icon=NSImage(contentsOfFile:source)}else{
            let hex=req["color"] as? String ?? "7863E6";var number:UInt64=0;Scanner(string:hex).scanHexInt64(&number);let color=NSColor(srgbRed:CGFloat((number>>16)&255)/255,green:CGFloat((number>>8)&255)/255,blue:CGFloat(number&255)/255,alpha:1)
            let symbol=req["symbol"] as? String ?? "folder.fill"
            let image=NSImage(size:NSSize(width:128,height:128));image.lockFocus();color.set();let base=NSBezierPath(roundedRect:NSRect(x:10,y:15,width:108,height:85),xRadius:15,yRadius:15);base.fill();NSBezierPath(roundedRect:NSRect(x:10,y:85,width:47,height:27),xRadius:8,yRadius:8).fill();if let s=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:38,weight:.medium)){s.isTemplate=false;s.draw(in:NSRect(x:42,y:37,width:44,height:44),from:.zero,operation:.sourceOver,fraction:0.8)};image.unlockFocus();icon=image
        };guard icon != nil else{throw failure("无法读取图标")}}
        for p in paths{if !NSWorkspace.shared.setIcon(icon,forFile:p.path,options:[]){throw failure("不能设置图标：\(p.path)")}};return [:]
    case "airdrop":guard let service=NSSharingService(named:.sendViaAirDrop)else{throw failure("系统暂不支持隔空投送")};service.perform(withItems:paths);return ["message":"已打开隔空投送面板，请选择接收方。"]
    case "wallpaper":guard let p=paths.first else{throw failure("请选择图片")};for screen in NSScreen.screens{try NSWorkspace.shared.setDesktopImageURL(p,for:screen,options:[:])};return [:]
    case "extension_hidden":for var p in paths{var val=URLResourceValues();val.hasHiddenExtension=req["hidden"] as? Bool ?? false;try p.setResourceValues(val)};return [:]
    case "finder_hidden":CFPreferencesSetAppValue("AppleShowAllFiles" as CFString,(req["show"] as? Bool ?? false) as CFBoolean,"com.apple.finder" as CFString);CFPreferencesAppSynchronize("com.apple.finder" as CFString);return ["message":"设置已保存。重新打开访达窗口后生效；部分系统版本需重启访达。"]
    case "translate":let provider=req["provider"] as? String ?? "google";let text=req["text"] as? String ?? "";var comp=URLComponents(string:provider=="baidu" ? "https://fanyi.baidu.com/mtpe-individual/multimodal":"https://translate.google.com/")!;comp.queryItems=[URLQueryItem(name:provider=="baidu" ? "query":"text",value:text),URLQueryItem(name:"sl",value:"auto"),URLQueryItem(name:"tl",value:"zh-CN"),URLQueryItem(name:"op",value:"translate")];NSWorkspace.shared.open(comp.url!);return [:]
    case "settings":let pane=req["pane"] as? String ?? "extensions";let url=URL(string:pane=="disk" ? "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" : pane=="accessibility" ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" : "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.FinderSync")!;NSWorkspace.shared.open(url);return [:]
    case "menu_catalog": return FinderMenu.catalog(req["config"] as? [String:Any] ?? [:])
    case "status":
        let extensions=FIFinderSyncController.isExtensionEnabled
        return ["finderEnabled":extensions,"accessibility":AXIsProcessTrusted(),"login":SMAppService.mainApp.status == .enabled]
    case "login":if req["enabled"] as? Bool ?? false{try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()};return [:]
    case "apply_settings":controller.apply(req["config"] as? [String:Any] ?? [:]);return [:]
    case "preview":guard let p=paths.first else{throw failure("请选择图片")};let preview=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.Preview")!;NSWorkspace.shared.open([p],withApplicationAt:preview,configuration:NSWorkspace.OpenConfiguration());return [:]
    case "pin":guard let p=paths.first,let image=NSImage(contentsOf:p)else{throw failure("请选择图片")};let size=image.size;let width=min(size.width,500),height=min(size.height*width/max(size.width,1),600);let panel=NSPanel(contentRect:NSRect(x:150,y:150,width:width,height:height),styleMask:[.titled,.closable,.resizable,.utilityWindow],backing:.buffered,defer:false);panel.title=p.lastPathComponent;panel.level = .floating;let view=NSImageView(frame:NSRect(x:0,y:0,width:width,height:height));view.image=image;view.imageScaling = .scaleProportionallyUpOrDown;panel.contentView=view;panel.makeKeyAndOrderFront(nil);controller.panels.append(panel);return [:]
    case "screenshot":let directory=req["dir"] as? String ?? NSTemporaryDirectory();let dest=URL(fileURLWithPath:directory).appendingPathComponent("截图-\(UUID().uuidString.prefix(8)).png");let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");process.arguments=["-i",dest.path];try process.run();return ["message":"按系统提示选择截图区域，图片将保存至当前目录。","path":dest.path]
    default:throw failure("未知系统操作：\(cmd)")
    }
}
func failure(_ text:String)->NSError{NSError(domain:"RightClick",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
@_cdecl("rustclick_native") public func nativeCall(_ p:UnsafePointer<CChar>?)->UnsafeMutablePointer<CChar>? {guard let p=p else{return nil};let req=decode(String(cString:p));var result:[String:Any]=[:];let work={do{result=try nativeWork(req)}catch{result=["error":error.localizedDescription]}};if Thread.isMainThread{work()}else{DispatchQueue.main.sync(execute:work)};return strdup(encode(result))}

class AppController:NSObject,NSApplicationDelegate,WKScriptMessageHandler,WKNavigationDelegate,NSWindowDelegate {
    let finderUI = DesktopFinderUI()
    var window:NSWindow!;var web:WKWebView!;var status:NSStatusItem?;var panels=[NSPanel]();var config=[String:Any]();var pending:[[String:Any]]=[];var ready=false;var monitor:Any?;var floatingMenu:NSMenu?;var finderPaths=[String]();var finderDir=""
    func applicationDidFinishLaunching(_ notification:Notification){
        let menu=NSMenu();let root=NSMenuItem();menu.addItem(root);let app=NSMenu();app.addItem(withTitle:"关于 RightClick",action:#selector(about),keyEquivalent:"");app.addItem(.separator());app.addItem(withTitle:"显示 RightClick",action:#selector(show),keyEquivalent:"1");app.addItem(withTitle:"退出 RightClick",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");root.submenu=app;let edit=NSMenuItem();edit.title="编辑";menu.addItem(edit);let em=NSMenu(title:"编辑");for (t,a,k) in [("撤销","undo:","z"),("剪切","cut:","x"),("拷贝","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")]{em.addItem(withTitle:t,action:Selector(a),keyEquivalent:k)};edit.submenu=em;NSApp.mainMenu=menu
        let conf=WKWebViewConfiguration();conf.userContentController.add(self,name:"rustclick");web=WKWebView(frame:.zero,configuration:conf);web.navigationDelegate=self;web.setValue(false,forKey:"drawsBackground")
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false);window.title="RightClick · 右键工具箱";window.minSize=NSSize(width:960,height:640);window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true;window.backgroundColor=NSColor(srgbRed:0.961,green:0.961,blue:0.969,alpha:1);window.contentView=web;window.delegate=self;window.isReleasedWhenClosed=false;window.center();window.setFrameAutosaveName("RustClickMain");
        let url=Bundle.main.resourceURL!.appendingPathComponent("ui/index.html");web.loadFileURL(url,allowingReadAccessTo:Bundle.main.resourceURL!.appendingPathComponent("ui"));if FinderRequestRouting.showsWindowOnLaunch(notification){show()}
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(publish),name:Notification.Name("dev.rustclick.requestConfig"),object:nil)
        worker.async {let s=engine(["cmd":"state"]);let c=(s["data"] as? [String:Any])?["config"] as? [String:Any] ?? [:];DispatchQueue.main.async{self.apply(c)}}
        NSApp.servicesProvider=self
    }
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){let url=action.request.url;decisionHandler(url?.isFileURL==true && url!.path.hasPrefix(Bundle.main.resourceURL!.appendingPathComponent("ui").path+"/") ? .allow:.cancel)}
    func userContentController(_ c:WKUserContentController,didReceive message:WKScriptMessage){guard message.frameInfo.isMainFrame,let body=message.body as? [String:Any],let id=body["id"] as? Int,let req=body["request"] as? [String:Any]else{return};if req["cmd"] as? String == "ready"{ready=true;for v in pending{incoming(v)};pending=[];resolve(id,["ok":true,"data":[:]]);return};worker.async{let result=engine(req);DispatchQueue.main.async{self.resolve(id,result)}}}
    func resolve(_ id:Int,_ v:[String:Any]){web.evaluateJavaScript("window.__resolve(\(id),\(encode(v)))",completionHandler:nil)}
    func incoming(_ v:[String:Any]) {
        FinderRequestRouting.route(v, execute: { request in
            worker.async {
                let actions = FinderActions(execute: { request in
                    if request["cmd"] as? String != "state" { self.finderUI.begin() }
                    let result = engine(request)
                    guard result["ok"] as? Bool == true else {
                        throw FinderActionFailure(message:result["error"] as? String ?? "操作失败")
                    }
                    return result["data"] as? [String:Any] ?? [:]
                }, ui:self.finderUI)
                do { self.finderUI.finish(try actions.run(request)) }
                catch { self.finderUI.finish(nil); self.finderUI.result("操作未完成",text:error.localizedDescription,paths:[]) }
            }
        }, present: { request in
            if !self.ready { self.pending.append(request); return }
            self.show()
            self.web.evaluateJavaScript("window.receiveFinder(\(encode(request)))",completionHandler:nil)
        })
    }
    func application(_ application:NSApplication,open urls:[URL]){for url in urls{guard url.scheme=="rustclick",url.host=="request",let id=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="id"})?.value,UUID(uuidString:id) != nil else{continue};let board=NSPasteboard(name:NSPasteboard.Name("dev.rustclick.request."+id));guard let text=board.string(forType:.string)else{continue};board.clearContents();let req=decode(text);incoming(req)}}
    func applicationDidBecomeActive(_ notification:Notification){if ready{web.evaluateJavaScript("window.refreshNativeStatus?.()",completionHandler:nil)}}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{show();return true}
    func windowShouldClose(_ sender:NSWindow)->Bool{sender.orderOut(nil);return false}
    @objc func show(){window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc func trayAction(_ sender:NSStatusBarButton) {
        guard NSApp.currentEvent?.type == .rightMouseUp else { show(); return }
        let menu = NSMenu(title:"RightClick")
        let open = menu.addItem(withTitle:"打开 RightClick",action:#selector(show),keyEquivalent:"")
        open.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle:"退出 RightClick",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"")
        quit.target = NSApp
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.minY-4),in:sender)
    }
    @objc func about(){let a=NSAlert();a.messageText="RightClick 0.1.0";a.informativeText="Rust 驱动的 macOS 右键工具箱\n所有功能免费，无账号、无订阅。\n独立实现，与 Better365 无关联。";a.runModal()}
    @objc func publish(){let text=encode(config);let board=NSPasteboard(name:NSPasteboard.Name("dev.rustclick.menuConfig"));board.clearContents();board.setString(text,forType:.string);DistributedNotificationCenter.default().postNotificationName(Notification.Name("dev.rustclick.config"),object:text,userInfo:nil,deliverImmediately:true)}
    func apply(_ config:[String:Any]){self.config=config;if config["showTray"] as? Bool ?? true{if status==nil{status=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength);status?.button?.image=NSImage(systemSymbolName:"cursorarrow.click",accessibilityDescription:"RightClick");status?.button?.action = #selector(trayAction(_:));status?.button?.target=self;status?.button?.toolTip="RightClick · 单击打开，右键查看更多";status?.button?.setAccessibilityLabel("RightClick");status?.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])}}else if let s=status{NSStatusBar.system.removeStatusItem(s);status=nil};publish();if let m=monitor{NSEvent.removeMonitor(m);monitor=nil};if config["cloudShortcut"] as? Bool ?? false{monitor=NSEvent.addGlobalMonitorForEvents(matching:[.rightMouseDown,.otherMouseDown]){e in if (e.type == .rightMouseDown && e.modifierFlags.contains(.shift)) || e.type == .otherMouseDown{self.cloudMenu()}}}}
    func cloudMenu(){do{let selected=try apple("tell application \"Finder\"\nset output to {}\nrepeat with itemRef in (get selection)\nset end of output to POSIX path of (itemRef as alias)\nend repeat\nreturn output\nend tell");finderPaths=(1...max(selected.numberOfItems,1)).compactMap{selected.atIndex($0)?.stringValue};finderDir=(try? apple("tell application \"Finder\" to get POSIX path of (target of front Finder window as alias)").stringValue) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path;let m=NSMenu(title:"RightClick");for (title,cmd) in [("新建文件…","create"),("剪切","cut"),("粘贴","paste"),("复制到…","copy"),("移动到…","move"),("拷贝路径","copy_path"),("文件信息","info"),("图片转换…","convert"),("打开操作台","workbench")]{let item=NSMenuItem(title:title,action:#selector(cloudAction(_:)),keyEquivalent:"");item.target=self;item.representedObject=cmd;m.addItem(item)};floatingMenu=m;m.popUp(positioning:nil,at:NSEvent.mouseLocation,in:nil)}catch{finderUI.result("无法读取访达选择",text:error.localizedDescription,paths:[])}}
    @objc func cloudAction(_ item:NSMenuItem){incoming(["cmd":item.representedObject as? String ?? "workbench","paths":finderPaths,"dir":finderDir])}
    @objc func translateGoogle(_ pb:NSPasteboard,userData:String?,error:AutoreleasingUnsafeMutablePointer<NSString?>){incoming(["cmd":"text","text":pb.string(forType:.string) ?? "","provider":"google"])}
    @objc func generateQR(_ pb:NSPasteboard,userData:String?,error:AutoreleasingUnsafeMutablePointer<NSString?>){incoming(["cmd":"text","text":pb.string(forType:.string) ?? ""])}
}
@_cdecl("rustclick_start") public func start(_ callback:@escaping @convention(c)(UnsafePointer<CChar>?)->UnsafeMutablePointer<CChar>?,_ free:@escaping @convention(c)(UnsafeMutablePointer<CChar>?)->Void){backend=callback;releaseBackend=free;let app=NSApplication.shared;app.setActivationPolicy(.accessory);controller=AppController();app.delegate=controller;app.run()}
