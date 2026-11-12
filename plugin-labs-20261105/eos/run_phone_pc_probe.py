"""Authorized USB deployment + bounded PC/phone EOS test. Never print credentials or IDs."""
from pathlib import Path
import subprocess,os,time,json,secrets,re,zipfile,sys,hashlib
r=Path(__file__).resolve().parent
root=r.parents[1]
if sys.argv[1:2] == ['--pc-menu']:
    # PC 游戏复用同一份本机 EOS 配置路径，不走 APK、ADB 或部署流程。
    config = root / 'private-local/eos/eosg-dev.env'
    if not config.is_file():
        sys.exit('PC EOS configuration is missing.')
    args = sys.argv[2:]
    environment = dict(os.environ, RACER_EOS_CONFIG=str(config))
    suffix = '_console' if '--headless' in args else ''
    engine = f'E:/godot4.72/Godot_v4.7.2-stable_win64{suffix}.exe'
    sys.exit(subprocess.call([engine, '--path', str(root / 'godot-racer'), *args], env=environment))
pc_menu_admission = '--pc-menu-phone-admission' in sys.argv
if pc_menu_admission and '--skip-install' not in sys.argv:
    sys.exit('PC menu admission requires the existing phone app and --skip-install.')
invite_only='--invite-only' in sys.argv
if pc_menu_admission:
    private = root / 'private-local/eos-pc-menu-20261111'
else:
    private = root / ('private-local/eos-invite-20261111' if invite_only else 'private-local/eos-dual-20261106')
private.mkdir(parents=True,exist_ok=True)
config=root/'private-local/eos/eosg-dev.env'
project=r/'cross-platform-probe'
apk=r/'racer-eos-probe.apk'
adb='E:/AndroidSdk/platform-tools/adb.exe'
pkg='org.godotracer.eosprobe'
profile=r/'cross-profile'
room_ui='--room-ui' in sys.argv
room_flow='--room-flow' in sys.argv or room_ui or invite_only
phone_host='--phone-host' in sys.argv
native_tick='--native-tick' in sys.argv
trace_native='--trace-native-p2p' in sys.argv
pc_initiates='--mesh-pc-initiates' in sys.argv
listener_first='--mesh-listener-first' in sys.argv or pc_initiates
mesh_probe='--mesh-probe' in sys.argv or listener_first
if mesh_probe and (not room_flow or room_ui or invite_only or pc_menu_admission):
 sys.exit('--mesh-probe requires --room-flow without the UI or admission variants.')
if phone_host and (not room_flow or room_ui or invite_only or pc_menu_admission or mesh_probe or '--skip-install' not in sys.argv):
 sys.exit('--phone-host requires --skip-install --room-flow without the other probe variants.')
if native_tick and ('--skip-install' not in sys.argv or '--room-flow' not in sys.argv or invite_only or pc_menu_admission or room_ui):
 sys.exit('--native-tick requires --skip-install --room-flow without the UI or admission variants.')
if trace_native and ('--skip-install' not in sys.argv or '--room-flow' not in sys.argv or invite_only or pc_menu_admission or room_ui):
 sys.exit('--trace-native-p2p requires --skip-install --room-flow without the UI or admission variants.')
ui_hashes={}
ui_files={name:root/path for name,path in {
 'online_room_session.gd':'godot-racer/scripts/online_room_session.gd',
 'online_room_view.gd':'godot-racer/scripts/online_room_view.gd',
 'racing_style.gd':'godot-racer/scripts/racing_style.gd',
 'room_preview.png':'godot-racer/assets/ui/tracks/level_2.png'}.items()}
room_module=root/'godot-racer/scripts/online_room_state.gd'
room_module_hash=''
room_config={}
if room_flow:
 evidence=root/('evidence/online-room-ui-20261107' if room_ui else 'evidence/online-room-20261106')
 if invite_only:evidence=root/'evidence/eos-invite-20261111'/time.strftime('live-%Y%m%d-%H%M%S')
 if mesh_probe:evidence=root/'evidence'/time.strftime('pc-phone-eos-mesh-%Y%m%d-%H%M%S')
 if listener_first:evidence=root/'evidence'/time.strftime('pc-phone-eos-listener-first-%Y%m%d-%H%M%S')
 if pc_initiates:evidence=root/'evidence'/time.strftime('pc-phone-eos-pc-initiates-%Y%m%d-%H%M%S')
 if phone_host:evidence=root/'evidence'/time.strftime('pc-phone-eos-phone-host-%Y%m%d-%H%M%S')
 if native_tick:evidence=root/'evidence'/time.strftime('pc-phone-eos-native-tick-%Y%m%d-%H%M%S')
 if trace_native:evidence=root/'evidence'/time.strftime('pc-phone-eos-native-trace-%Y%m%d-%H%M%S')
 evidence.mkdir(parents=True,exist_ok=True)
 verification=subprocess.run(['E:/godot4.72/Godot_v4.7.2-stable_win64.exe','--headless','--path',str(root/'godot-racer'),
  '--script','res://tools/test_online_room_state.gd','--','--export-rules='+str(evidence/'room-rules.json'),
  '--export-room-ui='+str(evidence/'room-ui-info.json')],
  env=dict(os.environ,APPDATA=str(evidence/'profile'),LOCALAPPDATA=str(evidence/'profile')),
  stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45,creationflags=subprocess.CREATE_NO_WINDOW)
 (evidence/'local-state.log').write_bytes(verification.stdout)
 if verification.returncode or b'SCRIPT ERROR' in verification.stdout or b'failures=0' not in verification.stdout:
  raise RuntimeError('local_room_state_verification_failed_see_evidence_log')
 room_config=json.loads((evidence/'room-rules.json').read_text(encoding='utf-8'))
 print('PASS local_room_state_and_existing_L2_rules',flush=True)
if pc_menu_admission:
    evidence = root / 'evidence/online-pc-menu-20261111' / time.strftime('phone-admission-%Y%m%d-%H%M%S')
    evidence.mkdir(parents=True)
output_dir=evidence if invite_only or pc_menu_admission or mesh_probe or phone_host or native_tick or trace_native else r
values={}
for line in config.read_text(encoding='utf-8-sig').splitlines():
 if '=' in line and not line.lstrip().startswith('#'):
  k,v=line.split('=',1);values[k]=v.strip().strip(chr(34))
redactions=[v for k,v in values.items() if k.endswith(('_ID','_SECRET','_KEY')) and v]
def clean(s):
 for v in sorted(redactions,key=len,reverse=True):s=s.replace(v,'[REDACTED]')
 s=re.sub(r'(?i)((?:access_token|refresh_token|continuance_token)[" :=]+)[^,}\s]+',r'\1[REDACTED]',s)
 return s
def adb_run(args,**kw):
 return subprocess.run([adb,*args],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=kw.pop('timeout',30),**kw)
def inject(name,data):
 result=adb_run(['shell','run-as',pkg,'tee','files/'+name],input=data)
 if result.returncode:raise RuntimeError('private_app_write_failed_'+name)
def start_phone(payload):
 inject('config.env',config.read_bytes())
 inject('session.json',payload)
 adb_run(['shell','am','force-stop',pkg])
 adb_run(['shell','run-as',pkg,'rm','-f','files/result.json','files/export-session.json'])
 if room_ui:adb_run(['shell','run-as',pkg,'rm','-f','files/room-ui-ready.png','files/room-ui-revised.png'])
 started=adb_run(['shell','am','start','-n',pkg+'/com.godot.game.GodotAppLauncher'])
 print('PHONE_APP_STARTED',started.returncode==0,flush=True)
 if started.returncode or b'Error' in started.stdout:raise RuntimeError('phone_app_start_failed')
def read_phone_json(name):
 result=adb_run(['exec-out','run-as',pkg,'cat','files/'+name])
 if result.returncode==0:
  try:
   parsed=json.loads(result.stdout)
   if isinstance(parsed,dict):return parsed
  except json.JSONDecodeError:pass
 return {}
def phone_lobby_pending():
 return adb_run(['shell','run-as',pkg,'test','-s','files/pending-lobby.txt']).returncode==0
def inject_asset(name,path):
 # Only non-sensitive UI assets use shell-readable staging; config.env never uses this path.
 staged='/data/local/tmp/racer-ui-'+secrets.token_hex(8)
 try:
  pushed=adb_run(['push',str(path),staged])
  copied=adb_run(['shell','run-as',pkg,'cp',staged,'files/'+name])
  verified=adb_run(['exec-out','run-as',pkg,'sha256sum','files/'+name])
  expected=hashlib.sha256(path.read_bytes()).hexdigest().encode()
  if pushed.returncode or copied.returncode or verified.returncode or verified.stdout.split()[:1]!=[expected]:
   raise RuntimeError('binary_asset_transfer_failed_'+name)
 finally:
  adb_run(['shell','rm','-f',staged])
# Check the built package contains no locally configured secret or product identifiers.
with zipfile.ZipFile(apk) as z:
 for name in z.namelist():
  data=z.read(name)
  if any(v.encode() in data for v in redactions):raise RuntimeError('credential_found_in_apk')
print('PASS apk_contains_no_configured_credentials',flush=True)
if '--skip-install' not in sys.argv:
 result=adb_run(['install','-r',str(apk)],timeout=120)
 print('APK_INSTALL',clean(result.stdout.decode(errors='replace')).strip(),flush=True)
 if result.returncode:print(clean(result.stderr.decode(errors='replace')));sys.exit(2)
if adb_run(['shell','run-as',pkg,'mkdir','-p','files']).returncode:raise RuntimeError('run_as_unavailable')
session={'host':True,'nonce':secrets.token_hex(8),'relay':'--allow-relays' not in sys.argv}
if room_ui:session['room_ui']=True
if room_flow:
 session.update(room_flow=True,code=''.join(secrets.choice('ABCDEFGHJKLMNPQRSTUVWXYZ23456789') for _ in range(8)),config=room_config)
 if '--rotate-invite-before-join' in sys.argv:session['rotate_invite_before_join']=True
 if invite_only:session.update(invite_only=True,rotate_invite_before_join=True)
 if mesh_probe:session['mesh_probe']=True
 if listener_first:session['mesh_listener_first']=True
 if pc_initiates:session['mesh_pc_initiates']=True
 if native_tick:session['native_tick']=True
(private/'session.json').write_text(json.dumps(session),encoding='utf-8')
for name in ['export-session.json','result.json']:
 f=private/name
 if f.exists():f.unlink()
env=dict(os.environ,APPDATA=str(profile),LOCALAPPDATA=str(profile),RACER_EOS_CONFIG=str(config),RACER_TEST_ROOT=str(private),RACER_ROOM_MODULE=str(room_module),RACER_ROOM_UI_ROOT=str(root/'godot-racer'),
 RACER_ROOM_UI_INFO=str(evidence/'room-ui-info.json') if room_ui else '')
command=['E:/godot4.72/Godot_v4.7.2-stable_win64.exe','--headless','--path',str(project),'--audio-driver','Dummy']
test_command=command+['--','--connect-diagnostics'] if invite_only else command
if pc_menu_admission:
    (evidence / 'profile').mkdir()
    verify = evidence.parent / 'verify_menu.gd'
    test_command = ['E:/godot4.72/Godot_v4.7.2-stable_win64_console.exe', '--headless',
                    '--path', str(root / 'godot-racer'), '--audio-driver', 'Dummy', '--script', str(verify)]
    env.update(RACER_PC_MENU_TEST_ROLE='host', RACER_PC_MENU_TEST_KIND='phone',
               RACER_PC_MENU_TEST_SYNC=str(private), APPDATA=str(evidence/'profile'), LOCALAPPDATA=str(evidence/'profile'))
if trace_native:
 import ctypes
 ndk=Path('E:/AndroidSdk/ndk/27.1.12297006/toolchains/llvm/prebuilt/windows-x86_64')
 bundled_python=ndk/'python3'
 lldb_exe=ndk/'bin/lldb.exe'
 if not lldb_exe.is_file() or not (bundled_python/'python311.dll').is_file():
  sys.exit('Installed NDK debugger or bundled Python DLL is missing.')
 ctypes.windll.kernel32.SetErrorMode(0x8003)
 env.update(PYTHONHOME=str(bundled_python), PATH=str(bundled_python)+os.pathsep+env['PATH'])
 trace_script=(r/'trace_eos_p2p.py').as_posix()
 test_command=[str(lldb_exe),'--batch','-o','settings set target.skip-prologue false',
  '-o',f'command script import "{trace_script}"',
  '-o','script trace_eos_p2p.install(lldb.debugger)','-o','run','--',*test_command]
raw_path=private/'pc-raw.log'
with raw_path.open('wb') as output:
 pc=None
 phone={}
 probe_hash=''
 try:
  if not phone_host:
   pc=subprocess.Popen(test_command,env=env,stdout=output,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
   deadline=time.monotonic()+60
   while not (private/'export-session.json').exists() and pc.poll() is None and time.monotonic()<deadline:time.sleep(.5)
   if not (private/'export-session.json').exists():raise RuntimeError('pc_lobby_not_ready')
  probe_source=(project/'probe.gd').read_text(encoding='utf-8').encode('utf-8')
  if any(v.encode() in probe_source for v in redactions):raise RuntimeError('credential_found_in_probe_script')
  inject('network_probe.gd',probe_source)
  probe_hash=hashlib.sha256(probe_source).hexdigest()
  if room_flow:
   module_source=room_module.read_text(encoding='utf-8').encode('utf-8')
   if any(v.encode() in module_source for v in redactions):raise RuntimeError('credential_found_in_room_module')
   inject('online_room_state.gd',module_source)
   room_module_hash=hashlib.sha256(module_source).hexdigest()
   if not phone_host:
    admission=json.loads((private/'export-session.json').read_text(encoding='utf-8'))
    if 'lobby_id' in admission or 'nonce' in admission or len(admission.get('code',''))!=8:
     raise RuntimeError('room_code_discovery_not_isolated')
    if invite_only and (admission.get('invite_only') is not True or admission.get('expired_code')!=session['code'] or admission['code']==session['code']):
     raise RuntimeError('distinct_rotated_code_not_exported')
  if room_ui:
   for name,path in {**ui_files,'room-ui-info.json':evidence/'room-ui-info.json'}.items():
    data=path.read_bytes()
    if any(v.encode() in data for v in redactions):raise RuntimeError('credential_found_in_ui_asset')
    inject_asset(name,path)
    ui_hashes[name]=hashlib.sha256(data).hexdigest()
  if pc_menu_admission:
   admission=json.loads((private/'export-session.json').read_text(encoding='utf-8'))
   if set(admission) != {'host','code','pc_menu_admission'} or len(admission['code']) != 8:
    raise RuntimeError('formal_room_code_discovery_not_isolated')
  if phone_host:
   if phone_lobby_pending():raise RuntimeError('previous_phone_lobby_cleanup_pending')
   start_phone(json.dumps(session).encode('utf-8'))
   deadline=time.monotonic()+60
   admission={}
   while time.monotonic()<deadline:
    admission=read_phone_json('export-session.json')
    if admission:break
    phone=read_phone_json('result.json')
    if phone.get('finished'):break
    time.sleep(.5)
   if not admission:raise RuntimeError('phone_lobby_not_ready')
   expected_keys={'host','code','relay','room_flow'}
   if native_tick:expected_keys.add('native_tick')
   if set(admission)!=expected_keys or admission['host'] is not False or admission['code']!=session['code']:
    raise RuntimeError('phone_host_invite_export_invalid')
   (private/'session.json').write_text(json.dumps(admission),encoding='utf-8')
   pc=subprocess.Popen(test_command,env=env,stdout=output,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
  else:
   start_phone((private/'export-session.json').read_bytes())
  deadline=time.monotonic()+160
  phone={}
  while time.monotonic()<deadline:
   phone=read_phone_json('result.json') or phone
   if phone.get('finished') and pc.poll() is not None:break
   time.sleep(2)
  if pc.poll() is None:pc.wait(timeout=15)
  print('PHONE_RESULT',json.dumps(phone),flush=True)
  (private/'phone-result.json').write_text(json.dumps(phone),encoding='utf-8')
 except (RuntimeError,subprocess.TimeoutExpired) as exc:
  print('TEST_BLOCKER',str(exc),flush=True)
 finally:
  if pc is not None and pc.poll() is None:
   pc.kill();pc.wait()
  if not phone.get('finished'):adb_run(['shell','am','force-stop',pkg])
  try:
   if phone_host and phone_lobby_pending():
    start_phone(b'{"cleanup_lobby":true}')
    deadline=time.monotonic()+45
    while phone_lobby_pending() and time.monotonic()<deadline:time.sleep(1)
  finally:
   inject('config.env',b'')
   inject('session.json',b'{}')
text=clean(raw_path.read_text(encoding='utf-8',errors='replace'))
(output_dir/'pc-dual-sanitized.log').write_text(text,encoding='utf-8')
pc_result={}
if (private/'result.json').exists():
 try:pc_result=json.loads((private/'result.json').read_text(encoding='utf-8'))
 except json.JSONDecodeError:pass
phone_log=''
phone_pid=adb_run(['shell','pidof',pkg]).stdout.decode().strip()
if phone_pid.isdigit():
 phone_log=clean(adb_run(['logcat','-d','--pid='+phone_pid,'-v','brief','godot:E','Godot:E','*:S']).stdout.decode('utf-8',errors='replace'))
 (output_dir/'phone-dual-sanitized.log').write_text(phone_log,encoding='utf-8')

for line in text.splitlines():
 if line.startswith(('PASS ','FAIL ','EOS_PROBE','MENU_','EOS_NATIVE_P2P ')) or 'SCRIPT ERROR' in line:print(line)
if (private/'pending-lobby.txt').exists():
 with subprocess.Popen(command+['--','--cleanup-lobby'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW) as process:
  try:out,_=process.communicate(timeout=55)
  except subprocess.TimeoutExpired:process.kill();out,_=process.communicate()
 (output_dir/'pc-cleanup-sanitized.log').write_text(clean(out.decode('utf-8',errors='replace')),encoding='utf-8')
 print('PENDING_LOBBY', (private/'pending-lobby.txt').exists())
pc_exit=pc.returncode if pc is not None else 1
pending_lobby=(private/'pending-lobby.txt').exists() or (phone_host and phone_lobby_pending())
print('PC_EXIT',pc_exit)


mode_key='invite_only_passed' if invite_only or pc_menu_admission else 'dual_transfer_passed'
success=(pc_exit==0 and pc_result.get('finished') is True and pc_result.get('failures')==0
 and pc_result.get(mode_key) is True and phone.get('finished') is True
 and phone.get('usb_script_sha256')==probe_hash
 and phone.get('failures')==0 and phone.get(mode_key) is True
 and 'SCRIPT ERROR' not in text and 'SCRIPT ERROR' not in phone_log
 and not pending_lobby)
if phone_host:
 success=success and phone.get('host') is True and pc_result.get('host') is False
if native_tick:
 success=success and all(side.get('transport_diagnostics',{}).get('tick_budget_ms')==0 for side in (pc_result,phone))
if room_flow:
 success=(success and phone.get('room_module_sha256')==room_module_hash and pc_result.get('room_module_sha256')==room_module_hash)
 if not invite_only:success=(success and pc_result.get('room_flow_passed') is True and phone.get('room_flow_passed') is True)
if mesh_probe:
 expected_mode='mesh_listener_first' if listener_first else 'mesh'
 if pc_initiates:expected_mode='mesh_pc_initiates'
 success=success and all(side.get('transport_diagnostics',{}).get('peer_mode')==expected_mode for side in (pc_result,phone))
if room_ui:
 success=(success and pc_result.get('room_ui_passed') is True and phone.get('room_ui_passed') is True
  and pc_result.get('room_ui_hashes')==ui_hashes and phone.get('room_ui_hashes')==ui_hashes)
 for name in ['room-ui-ready.png','room-ui-revised.png']:
  captured=adb_run(['exec-out','run-as',pkg,'cat','files/'+name])
  if captured.returncode==0 and captured.stdout.startswith(b'\x89PNG'):(evidence/name).write_bytes(captured.stdout)
summary={'passed':success,'pc':pc_result,'phone':phone,'pc_exit':pc_exit,'phone_host':phone_host,
 'room_flow':room_flow,'room_ui':room_ui,'invite_only':invite_only,'pc_menu_admission':pc_menu_admission,
 'relay_policy':None if invite_only or pc_menu_admission else ('AllowRelays' if '--allow-relays' in sys.argv else 'ForceRelays'),'build_calls':0,'install_calls':0 if '--skip-install' in sys.argv else 1,
 'script_errors':('SCRIPT ERROR' in text or 'SCRIPT ERROR' in phone_log),
 'pending_lobby':pending_lobby}
(output_dir/'dual-result.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
print('DUAL_RESULT',json.dumps(summary),flush=True)
sys.exit(0 if success else 1)
