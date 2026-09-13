import Cocoa
// Finder serializes tag, but deliberately drops representedObject.
final class MenuActionStore {
    private var sequence=0
    private var requests=[Int:[String:Any]]()
    func bind(_ item:NSMenuItem, request:[String:Any]) {sequence+=1;item.tag=sequence;requests[sequence]=request}
    func request(for item:NSMenuItem)->[String:Any]? {requests[item.tag]}
    func reset() {requests.removeAll(keepingCapacity:true)}
}
