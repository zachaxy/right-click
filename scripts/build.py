#!/usr/bin/env python3
"""Build a self-contained local macOS .app; no Xcode account required."""
import os, pathlib, plistlib, shutil, subprocess, sys
from build_support import project_version, sevenzip_binary
ROOT=pathlib.Path(__file__).resolve().parents[1]
os.chdir(ROOT)
BUILD=ROOT/'build'; BUILD.mkdir(exist_ok=True)
DIST=ROOT/'dist'; DIST.mkdir(exist_ok=True)
APP=DIST/'RightClick.app'
version=project_version()
if os.uname().machine != 'arm64': raise RuntimeError('RightClick distribution builds require an Apple Silicon Mac')
def run(*args): subprocess.run([str(a) for a in args],check=True)
cargo=shutil.which('cargo') or str(pathlib.Path.home()/'.cargo/bin/cargo')
run(cargo,'build','--release','--locked')
arch=subprocess.check_output(['uname','-m'],text=True).strip()
target=f'{arch}-apple-macosx13.0'
run('swiftc','-emit-library','-O','-target',target,'-module-name','RustClickUI','native/MenuActionStore.swift','native/FinderMenu.swift','native/FinderRequestRouting.swift','native/FinderActions.swift','native/FinderActionUI.swift','native/App.swift','-o',BUILD/'libRustClickUI.dylib','-Xlinker','-install_name','-Xlinker','@rpath/libRustClickUI.dylib','-framework','Cocoa','-framework','WebKit','-framework','FinderSync','-framework','ServiceManagement')
run('swiftc','-emit-executable','-parse-as-library','-O','-target',target,'-module-name','RustClickFinder','native/FinderMenu.swift','native/MenuActionStore.swift','native/FinderRequestRouting.swift','native/FinderVolumeMonitor.swift','native/FinderSync.swift','-o',BUILD/'RustClickFinder','-framework','Cocoa','-framework','FinderSync','-Xlinker','-e','-Xlinker','_NSExtensionMain')
if APP.exists(): shutil.rmtree(APP)
contents=APP/'Contents';res=contents/'Resources';mac=contents/'MacOS';frameworks=contents/'Frameworks';ext=contents/'PlugIns/RightClickFinder.appex/Contents'
for p in [res,mac,frameworks,ext/'MacOS']:p.mkdir(parents=True,exist_ok=True)
shutil.copy2(ROOT/'target/release/rustclick',mac/'RightClick')
shutil.copy2(BUILD/'libRustClickUI.dylib',frameworks/'libRustClickUI.dylib')
shutil.copy2(BUILD/'RustClickFinder',ext/'MacOS/RightClickFinder')
shutil.copytree(ROOT/'ui',res/'ui')
index=res/'ui/index.html'
html=index.read_text()
if html.count('__RIGHTCLICK_VERSION__') != 1: raise RuntimeError('Missing UI version placeholder')
index.write_text(html.replace('__RIGHTCLICK_VERSION__',version))
seven=sevenzip_binary()
(res/'bin').mkdir();shutil.copy2(seven,res/'bin/7zz')
shutil.copy2(ROOT/'assets/7ZIP-LICENSE.txt',res/'7ZIP-LICENSE.txt')
run('swiftc','scripts/icon.swift','-o',BUILD/'make-icon','-framework','Cocoa')
run(BUILD/'make-icon',BUILD/'RustClick.iconset')
run('iconutil','-c','icns',BUILD/'RustClick.iconset','-o',res/'AppIcon.icns')
# The bundled Homebrew 7zz binary requires macOS 14, even though the UI targets 13.
base={'CFBundleInfoDictionaryVersion':'6.0','CFBundleShortVersionString':version,'CFBundleVersion':version,'LSMinimumSystemVersion':'14.0','CFBundleSupportedPlatforms':['MacOSX']}
info={**base,'CFBundleExecutable':'RightClick','CFBundleIdentifier':'dev.rustclick.app','CFBundleName':'RightClick','CFBundleDisplayName':'RightClick','CFBundlePackageType':'APPL','LSUIElement':True,'CFBundleIconFile':'AppIcon','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication','LSApplicationCategoryType':'public.app-category.utilities','NSAppleEventsUsageDescription':'RightClick 使用自动化在选定目录打开终端，或读取访达中你选中的文件。','CFBundleURLTypes':[{'CFBundleURLName':'RightClick Finder actions','CFBundleURLSchemes':['rustclick'],'CFBundleTypeRole':'Viewer'}],'NSServices':[{'NSMenuItem':{'default':'RightClick / 生成二维码'},'NSMessage':'generateQR','NSPortName':'RightClick','NSSendTypes':['NSStringPboardType','public.utf8-plain-text']},{'NSMenuItem':{'default':'RightClick / 翻译文字'},'NSMessage':'translateGoogle','NSPortName':'RightClick','NSSendTypes':['NSStringPboardType','public.utf8-plain-text']}]}
(ext/'Info.plist').write_bytes(plistlib.dumps({**base,'CFBundleIdentifier':'dev.rustclick.app.finder','CFBundleExecutable':'RightClickFinder','CFBundleName':'RightClick Finder','CFBundleDisplayName':'RightClick Finder','CFBundlePackageType':'XPC!','NSPrincipalClass':'NSApplication','LSUIElement':True,'NSExtension':{'NSExtensionPointIdentifier':'com.apple.FinderSync','NSExtensionPrincipalClass':'RustClickFinderSync','NSExtensionAttributes':{}}}))
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
ent=BUILD/'finder.entitlements';ent.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-write':True}))
for p in [res/'bin/7zz',frameworks/'libRustClickUI.dylib']:run('codesign','--force','--sign','-',p)
run('codesign','--force','--sign','-','--entitlements',ent,ext.parent)
run('codesign','--force','--sign','-',APP)
run('codesign','--verify','--deep','--strict',APP)
if '--install' in sys.argv:
 destination=pathlib.Path.home()/'Applications/RightClick.app'
 if destination.exists():shutil.rmtree(destination)
 shutil.copytree(APP,destination,symlinks=True)
 # Retire the previous product name only after the new signed bundle is installed.
 legacy=pathlib.Path.home()/'Applications/RustClick.app'
 if legacy.exists():
  previous=plistlib.loads((legacy/'Contents/Info.plist').read_bytes())
  if previous.get('CFBundleIdentifier')=='dev.rustclick.app':
   run('ditto','-c','-k','--sequesterRsrc','--keepParent',legacy,BUILD/'RustClick-before-rename.zip')
   run('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-u',legacy)
   subprocess.run(['/usr/bin/pluginkit','-r',str(legacy/'Contents/PlugIns/RustClickFinder.appex')],check=False)
   shutil.rmtree(legacy)
 run('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-f',destination)
 run('/usr/bin/pluginkit','-a',destination/'Contents/PlugIns/RightClickFinder.appex')
 print(f'Installed: {destination}')
print(f'Built: {APP}')
