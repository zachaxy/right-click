#!/usr/bin/env python3
"""Exercise the packaged Rust executable on isolated fixtures."""
import json, os, pathlib, subprocess, tempfile, zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
APP=ROOT/'dist/RightClick.app/Contents/MacOS/RightClick'
with tempfile.TemporaryDirectory(prefix='rustclick-smoke-') as tmp:
 root=pathlib.Path(tmp);env={**os.environ,'RUSTCLICK_DATA_DIR':str(root/'state')}
 env.pop('RUSTCLICK_7ZZ',None)
 def call(**request):
  result=subprocess.run([str(APP),'--request',json.dumps(request)],capture_output=True,text=True,env=env)
  response=json.loads(result.stdout)
  assert response['ok'],response
  return response['data']
 image=ROOT/'build/RustClick.iconset/icon_128x128.png'
 for fmt in ['png','jpg','webp','heic','icns','mac_icons','ios_icons']:
  result=call(cmd='convert',paths=[str(image)],dir=str(root),format=fmt)
  target=pathlib.Path(result['paths'][0]);assert target.exists(),target
  if fmt=='icns':assert target.read_bytes()[:4]==b'icns'
  if fmt=='mac_icons':assert len(list(target.glob('*.png')))==10
  if fmt=='ios_icons':assert json.loads((target/'Contents.json').read_text())['images']
  print('PASS image:',fmt)
 for fmt in ['docx','xlsx','pptx','psd','ai','rtf','svg','md','json']:
  result=call(cmd='create',dir=str(root),name='generated',format=fmt)
  target=pathlib.Path(result['paths'][0]);assert target.exists()
  if fmt in ['docx','xlsx','pptx']:
   with zipfile.ZipFile(target) as z:assert z.testzip() is None
  print('PASS template:',fmt)
 for fmt in ['zip','7z']:
  archive=call(cmd='archive7z',paths=[str(root/'generated.md')],dir=str(root),format=fmt,password='packaged-smoke')
  dest=call(cmd='extract_auto',paths=archive['paths'],dir=str(root),password='packaged-smoke')
  assert (pathlib.Path(dest['paths'][0])/'generated.md').exists()
  print('PASS encrypted archive:',fmt)
 print('PASS packaged app smoke checks')
