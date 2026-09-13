import Cocoa
let store=MenuActionStore()
let original=NSMenuItem(title:"复制到文稿",action:nil,keyEquivalent:"")
store.bind(original,request:["cmd":"copy","destination":"/test/Documents"])
let systemCopy=NSMenuItem(title:original.title,action:nil,keyEquivalent:"")
systemCopy.tag=original.tag
let result=store.request(for:systemCopy)
if result?["cmd"] as? String != "copy" { fputs("FAIL: Finder's copied menu item lost its action payload\n",stderr);exit(1) }
if result?["destination"] as? String != "/test/Documents" {exit(1)}
store.reset()
if store.request(for:systemCopy) != nil {fputs("FAIL: obsolete menus must not execute stale actions\n",stderr);exit(1)}
print("PASS: Finder menu item survives cross-process copying; stale actions are rejected")
