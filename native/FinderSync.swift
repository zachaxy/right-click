import Cocoa
import FinderSync

@objc(RustClickFinderSync)
final class RustClickFinderSync:FIFinderSync {
    var settings:[String:Any]=[:]
    let actions=MenuActionStore()
    private var volumeMonitor: FinderVolumeMonitor?
    override init() {
        super.init()
        volumeMonitor = FinderVolumeMonitor {
            FIFinderSyncController.default().directoryURLs = $0
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(update(_:)),
            name: Notification.Name("dev.rustclick.config"), object: nil)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("dev.rustclick.requestConfig"), object: nil,
            userInfo: nil, deliverImmediately: true)
        loadConfig()
    }
    func loadConfig(){if let s=NSPasteboard(name:NSPasteboard.Name("dev.rustclick.menuConfig")).string(forType:.string),let data=s.data(using:.utf8),let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]{settings=value}}
    @objc func update(_ n:Notification){if let s=n.object as? String,let data=s.data(using:.utf8),let c=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]{settings=c}}
    override var toolbarItemName:String{"RightClick"}
    override var toolbarItemToolTip:String{"新建文件与常用操作"}
    override var toolbarItemImage:NSImage{NSImage(systemSymbolName:"cursorarrow.click",accessibilityDescription:"RightClick") ?? NSImage(size:NSSize(width:20,height:20))}
    override func menu(for kind:FIMenuKind)->NSMenu? {
        loadConfig(); actions.reset()
        let control = FIFinderSyncController.default()
        if settings["externalDisks"] as? Bool == false, let target = control.targetedURL(),
           let values = try? target.resourceValues(forKeys:[.volumeIsInternalKey]), values.volumeIsInternal == false { return nil }
        return FinderMenu.build(settings,hasSelection:!(control.selectedItemURLs() ?? []).isEmpty,
                                toolbar:kind == .toolbarItemMenu,action:#selector(action(_:)),target:self,store:actions)
    }
    @objc func action(_ item:NSMenuItem){guard var request=actions.request(for:item)else{return};let c=FIFinderSyncController.default();let selected=c.selectedItemURLs() ?? [];let target=c.targetedURL();request["paths"]=selected.map{$0.path};if let t=target{let directory=(try? t.resourceValues(forKeys:[.isDirectoryKey]))?.isDirectory ?? false;request["dir"]=directory ? t.path:t.deletingLastPathComponent().path}else{request["dir"]=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path};if ["compress","compress7z","encrypt","extract"].contains(request["cmd"] as? String ?? ""),let first=selected.first {request["dir"]=first.deletingLastPathComponent().path};guard let data=try? JSONSerialization.data(withJSONObject:request),let s=String(data:data,encoding:.utf8)else{return};let id=UUID().uuidString;let board=NSPasteboard(name:NSPasteboard.Name("dev.rustclick.request."+id));board.clearContents();board.setString(s,forType:.string);
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let requestURL = URL(string:"rustclick://request?id="+id)!
        NSWorkspace.shared.open([requestURL], withApplicationAt:appURL,
                                configuration:FinderRequestRouting.openConfiguration()) { _, error in
            if let error = error {
                board.clearContents()
                NSLog("RightClick request failed: %@", error.localizedDescription)
            }
        }
    }
}
