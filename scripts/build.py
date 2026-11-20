#!/usr/bin/env python3
"""Build a self-contained local macOS .app; no Xcode account required."""
import os, pathlib, plistlib, shutil, subprocess, sys, tempfile
from build_support import bundle_version, project_version, sevenzip_binary, signing_identity, verify_install_identity
ROOT=pathlib.Path(__file__).resolve().parents[1]
os.chdir(ROOT)
BUILD=ROOT/'build'; BUILD.mkdir(exist_ok=True)
DIST=ROOT/'dist'; DIST.mkdir(exist_ok=True)
APP=DIST/'趁手.app'
version=project_version()
identity=signing_identity()
if os.uname().machine != 'arm64': raise RuntimeError('趁手 distribution builds require an Apple Silicon Mac')
def run(*args): subprocess.run([str(a) for a in args],check=True)
cargo=shutil.which('cargo') or str(pathlib.Path.home()/'.cargo/bin/cargo')
run(cargo,'build','--release','--locked')
arch=subprocess.check_output(['uname','-m'],text=True).strip()
target=f'{arch}-apple-macosx13.0'
run('swiftc','-emit-library','-O','-target',target,'-module-name','RustClickUI','native/MenuActionStore.swift','native/FinderMenu.swift','native/FinderRequestRouting.swift','native/FinderActions.swift','native/FinderActionUI.swift','native/ToolPanel.swift','native/ClipboardStore.swift','native/ClipboardPanel.swift','native/ClipboardStack.swift','native/ClipboardCoordinator.swift','native/ClipboardMCP.swift','native/InputSourceSettings.swift','native/InputSourceCoordinator.swift','native/EnglishPunctuation.swift','native/NetworkSpeedMonitor.swift','native/ToolboxIcon.swift','native/NetworkSpeedStatusImage.swift','native/TranslationPanel.swift','native/TranslationCoordinator.swift','native/App.swift','-o',BUILD/'libRustClickUI.dylib','-Xlinker','-install_name','-Xlinker','@rpath/libRustClickUI.dylib','-framework','Cocoa','-framework','WebKit','-framework','FinderSync','-framework','ServiceManagement','-framework','SystemConfiguration','-framework','Carbon','-framework','Vision','-framework','Quartz','-framework','SwiftUI','-Xlinker','-weak_framework','-Xlinker','Translation')
run('swiftc','-emit-executable','-parse-as-library','-O','-target',target,'-module-name','RustClickFinder','native/FinderMenu.swift','native/MenuActionStore.swift','native/FinderRequestRouting.swift','native/FinderVolumeMonitor.swift','native/ToolboxIcon.swift','native/FinderSync.swift','-o',BUILD/'RustClickFinder','-framework','Cocoa','-framework','FinderSync','-Xlinker','-e','-Xlinker','_NSExtensionMain')
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
iconset = BUILD/'AppIcon.iconset'
iconset.mkdir(exist_ok=True)
master = ROOT/'assets/AppIcon.png'
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = size * scale
        suffix = '@2x' if scale == 2 else ''
        rendition = iconset/f'icon_{size}x{size}{suffix}.png'
        if pixels == 1024:
            shutil.copyfile(master, rendition)
        else:
            run('sips', '--resampleHeightWidth', pixels, pixels, master, '--out', rendition)
run('iconutil','-c','icns',iconset,'-o',res/'AppIcon.icns')
# The bundled Homebrew 7zz binary requires macOS 14, even though the UI targets 13.
base={'CFBundleInfoDictionaryVersion':'6.0','CFBundleShortVersionString':version,'CFBundleVersion':bundle_version(version),'LSMinimumSystemVersion':'14.0','CFBundleSupportedPlatforms':['MacOSX']}
info={**base,'CFBundleExecutable':'RightClick','CFBundleIdentifier':'dev.rustclick.app','CFBundleName':'趁手','CFBundleDisplayName':'趁手','CFBundlePackageType':'APPL','LSUIElement':True,'CFBundleIconFile':'AppIcon','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication','LSApplicationCategoryType':'public.app-category.utilities','NSAppleEventsUsageDescription':'趁手使用自动化在选定目录打开终端，或读取访达中你选中的文件。','CFBundleURLTypes':[{'CFBundleURLName':'RightClick Finder actions','CFBundleURLSchemes':['rustclick'],'CFBundleTypeRole':'Viewer'}],'NSServices':[{'NSMenuItem':{'default':'趁手 / 生成二维码'},'NSMessage':'generateQR','NSPortName':'RightClick','NSSendTypes':['NSStringPboardType','public.utf8-plain-text']},{'NSMenuItem':{'default':'趁手 / 翻译文字'},'NSMessage':'translateGoogle','NSPortName':'RightClick','NSSendTypes':['NSStringPboardType','public.utf8-plain-text']}]}
(ext/'Info.plist').write_bytes(plistlib.dumps({**base,'CFBundleIdentifier':'dev.rustclick.app.finder','CFBundleExecutable':'RightClickFinder','CFBundleName':'趁手 Finder','CFBundleDisplayName':'趁手 Finder','CFBundlePackageType':'XPC!','NSPrincipalClass':'NSApplication','LSUIElement':True,'NSExtension':{'NSExtensionPointIdentifier':'com.apple.FinderSync','NSExtensionPrincipalClass':'RustClickFinderSync','NSExtensionAttributes':{}}}))
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
ent=BUILD/'finder.entitlements';ent.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-write':True}))
for p in [res/'bin/7zz',frameworks/'libRustClickUI.dylib']:run('codesign','--force','--sign',identity,p)
run('codesign','--force','--sign',identity,'--entitlements',ent,ext.parent)
run('codesign','--force','--sign',identity,APP)
run('codesign','--verify','--deep','--strict',APP)
if '--install' in sys.argv:
    applications = pathlib.Path.home()/'Applications'
    applications.mkdir(exist_ok=True)
    destination = applications/APP.name
    lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    legacy_apps = []
    for name in (APP.name, 'RightClick.app', 'RustClick.app'):
        installed = applications/name
        if not installed.exists():
            continue
        plist = installed/'Contents/Info.plist'
        if not plist.is_file() or plistlib.loads(plist.read_bytes()).get('CFBundleIdentifier') != info['CFBundleIdentifier']:
            if installed == destination:
                raise RuntimeError(f'An unrelated app already occupies {destination}')
            continue
        verify_install_identity(installed, APP)
        if installed != destination:
            legacy_apps.append(installed)

    # Stage the complete signed bundle before replacing an existing installation.
    with tempfile.TemporaryDirectory(prefix='.chenshou-install-', dir=applications) as temporary:
        staged = pathlib.Path(temporary)/APP.name
        run('ditto', APP, staged)
        run('codesign', '--verify', '--deep', '--strict', staged)
        previous = pathlib.Path(temporary)/'previous.app'
        if destination.exists():
            destination.rename(previous)
        try:
            staged.rename(destination)
        except OSError:
            if previous.exists():
                previous.rename(destination)
            raise

    # Back up each recognized old name before retiring its LaunchServices registration.
    for legacy in legacy_apps:
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', legacy, BUILD/f'{legacy.stem}-before-rename.zip')
        run(lsregister, '-u', legacy)
        for plugin in (legacy/'Contents/PlugIns').glob('*.appex'):
            subprocess.run(['/usr/bin/pluginkit', '-r', str(plugin)], check=False)
        shutil.rmtree(legacy)
    run(lsregister, '-f', destination)
    run('/usr/bin/pluginkit', '-a', destination/'Contents/PlugIns/RightClickFinder.appex')
    print(f'Installed: {destination}')
print(f'Built: {APP}')
