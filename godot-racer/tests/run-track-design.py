"""指定 console 引擎、独立运行目录、保留真实进程回执；不重试、不修改判据。"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding='utf-8')
p = argparse.ArgumentParser()
p.add_argument('tag')
p.add_argument('--mode', choices=['import', 'design', 'drive', 'check'], default='design')
p.add_argument('--check', choices=['layout', 'enclosure', 'lap', 'opponents', 'reset'])
p.add_argument('--godot', default='E:/godot/Godot_v4.4.1-stable_win64_console.exe')
p.add_argument('--render-fps', type=int, choices=[60, 120], default=60)
p.add_argument('--headless', action='store_true')
p.add_argument('--timeout', type=int, default=750)
p.add_argument('--bad-scene', action='store_true')
p.add_argument('--verbose', action='store_true')
a = p.parse_args()
if not re.fullmatch(r'[A-Za-z0-9_-]+', a.tag):
    p.error('需要唯一 ASCII 标签')
root = Path(__file__).resolve().parents[2]
out = root / 'godot-logs/track-L2-001' / a.tag
out.mkdir(parents=True, exist_ok=False)
sources = {}
for group in ['scripts', 'scenes', 'tests', 'data/levels']:
    for path in (root/'godot-racer'/group).rglob('*'):
        if path.is_file() and path.suffix in ['.gd','.tscn','.tres','.py']:
            sources[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
sources['godot-racer/project.godot'] = hashlib.sha256((root/'godot-racer/project.godot').read_bytes()).hexdigest()
(out/'run-source-hashes.json').write_text(json.dumps(sources,ensure_ascii=False,indent=2),encoding='utf-8')
env = os.environ.copy()
for key in ['APPDATA', 'LOCALAPPDATA']:
    local = out / key
    local.mkdir()
    env[key] = str(local)
command = [a.godot, '--path', str(root / 'godot-racer'), '--log-file', str(out / 'engine.log')]
command += ['--headless'] if a.headless else ['--rendering-method', 'forward_plus']
if a.verbose:
    command += ['--verbose']
if a.mode == 'import':
    command += ['--editor', '--import']
elif a.mode in ['design', 'drive']:
    command += ['--script', 'res://tests/track_%s_test.gd' % a.mode]
command += ['--', '--render-fps=%d' % a.render_fps, '--evidence-dir=' + str(out)]
if a.mode == 'check':
    if not a.check:
        p.error('--check 必填')
    command += ['--level=1', '--check=' + a.check]
if a.bad_scene:
    command += ['--bad-scene']
start = time.time()
with (out / 'stdout.log').open('wb') as stdout, (out / 'stderr.log').open('wb') as stderr:
    proc = subprocess.Popen(command, cwd=root, env=env, stdout=stdout, stderr=stderr)
    timed_out = False
    try:
        code = proc.wait(timeout=a.timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        # console引擎可能带子进程；只终止本包装器创建的进程树，保留终止回执。
        killed = subprocess.run(['taskkill','/PID',str(proc.pid),'/T','/F'],capture_output=True)
        (out/'termination-stdout.log').write_bytes(killed.stdout)
        (out/'termination-stderr.log').write_bytes(killed.stderr)
        if proc.poll() is None:
            proc.kill()
        code = proc.wait()
log = (out / 'stdout.log').read_text(encoding='utf-8', errors='replace') + (out / 'stderr.log').read_text(encoding='utf-8', errors='replace')
complete = re.search(r'TRACK_(?:DESIGN|DRIVE)_COMPLETE PASS=(\d+) FAIL=(\d+)', log)
script_errors = [s for s in log.splitlines() if re.search(r'SCRIPT ERROR|Parse Error|Leaked instance|ObjectDB instances leaked|Resources still in use', s)]
diagnostics = [s for s in log.splitlines() if re.search(r'ERROR:|WARNING:', s)]
unexpected_errors = [s for s in diagnostics if 'ERROR:' in s and 'Failed to read the root certificate store.' not in s
                     and not ((a.mode == 'design' or a.bad_scene) and '[赛道] 构建失败，拒绝发车' in s)]
passed = code == 0 and not timed_out and not script_errors and not unexpected_errors
if a.mode in ['design', 'drive']:
    passed &= complete is not None and int(complete[1]) > 0 and int(complete[2]) == 0
elif a.mode == 'check':
    passed &= bool(re.search(r'^OUTCOME\|', log, re.M))
receipt = dict(command=command, pid=proc.pid, exit_code=code, timed_out=timed_out,
               wall_seconds=time.time()-start, started_utc=datetime.datetime.fromtimestamp(start, datetime.timezone.utc).isoformat(),
               complete=complete[0] if complete else None, script_errors=script_errors,
               diagnostics=diagnostics, process_and_marker_passed=bool(passed),
               unexpected_errors=unexpected_errors,
               note='check 模式还须使用既有 check-result 判定器；证书等诊断保留，不称零错误')
(out / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2), encoding='utf-8')
if a.mode == 'check':
    judge = subprocess.run(['pwsh','-NoProfile','-File',str(Path(__file__).with_name('judge-track-check.ps1')),
                            '-Directory',str(out),'-Check',a.check],capture_output=True)
    (out/'judge-stdout.log').write_bytes(judge.stdout)
    (out/'judge-stderr.log').write_bytes(judge.stderr)
    passed &= judge.returncode == 0
    receipt['strict_judge_exit'] = judge.returncode
    receipt['process_and_marker_passed'] = bool(passed)
    (out/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(receipt, ensure_ascii=False, indent=2))
for line in log.splitlines():
    if 'TRACK_' in line or 'SCRIPT ERROR' in line:
        print(line)
raise SystemExit(0 if passed else 1)
