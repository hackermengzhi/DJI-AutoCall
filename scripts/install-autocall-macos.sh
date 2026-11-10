#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DJIAUTOCALL_SOURCE="$ROOT_DIR"

# Check before the potentially lengthy build, and again before changing runtime.
check_idle() {
  python3 - <<'PY'
import json
import urllib.error
import urllib.request
try:
    with urllib.request.urlopen('http://127.0.0.1:7575/api/calls/status', timeout=3) as response:
        status = json.load(response)
except urllib.error.URLError:
    status = {}
if status.get('active'):
    raise SystemExit('当前正在通话，请挂断后再安装。')
PY
}
check_idle
"$ROOT_DIR/scripts/build-macos.sh"
"$ROOT_DIR/macos/DJOneHubNotifier/build-app.sh"
check_idle

python3 - <<'PY'
import datetime
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import plistlib

root = Path(os.environ['DJIAUTOCALL_SOURCE'])
home = Path.home()
base = home / 'Library/Application Support/DJOneHub'
app = home / 'Applications/DJOneHub.app'
label = 'com.jamie.djonehub'
domain = 'gui/' + str(os.getuid())
subprocess.run(['launchctl', 'bootout', domain + '/' + label], capture_output=True)
exe = str(app / 'Contents/MacOS/DJOneHubNotifier')
for line in subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines():
    fields = line.strip().split(None, 1)
    if len(fields) == 2 and fields[1] == exe:
        try:
            os.kill(int(fields[0]), signal.SIGTERM)
        except ProcessLookupError:
            pass
stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
if app.exists():
    app.rename(app.with_name('DJOneHub.app.backup-' + stamp))
app.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ditto', str(root / 'macos/DJOneHubNotifier/dist/DJOneHubNotifier.app'), str(app)], check=True)
backend = base / 'runtime/bin/djonehub-macos'
backend.parent.mkdir(parents=True, exist_ok=True)
if backend.exists():
    shutil.copy2(backend, backend.with_name('djonehub-macos.backup-' + stamp))
shutil.copy2(root / 'dist/djonehub-macos', backend)
policy_file = base / 'network-policy.json'
policy = json.loads(policy_file.read_text()) if policy_file.exists() else {}
policy['force_off'] = True
policy.setdefault('services', [])
policy_file.write_text(json.dumps(policy, indent=2) + '\n')
policy_file.chmod(0o600)
# Disable existing, known module services without touching Wi-Fi.
services = subprocess.check_output(['networksetup', '-listallnetworkservices'], text=True)
for service in services.splitlines()[1:]:
    name = service.lstrip('*')
    if 'baiwang' in name.lower() or name == 'DJI 4G':
        result = subprocess.run(['networksetup', '-setnetworkserviceenabled', name, 'off'], capture_output=True)
        if result.returncode:
            print('请在系统网络设置中停用模块网络服务', name)
logs = home / 'Library/Logs/DJOneHub'
logs.mkdir(parents=True, exist_ok=True)
plist = home / ('Library/LaunchAgents/' + label + '.plist')
plist.parent.mkdir(parents=True, exist_ok=True)
if plist.exists():
    shutil.copy2(plist, plist.with_suffix('.plist.backup-' + stamp))
plist.write_bytes(plistlib.dumps({
    'Label': label,
    'ProgramArguments': [str(backend), '-listen', '127.0.0.1:7575', '-web-console'],
    'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
    'StandardOutPath': str(logs / 'launchd.log'),
    'StandardErrorPath': str(logs / 'launchd.log'),
}))
subprocess.run(['launchctl', 'bootstrap', domain, str(plist)], check=True)
subprocess.run(['open', str(app)], check=True)
print('DJI AutoCall 已安装。打开 DJOneHub 的“辅助通话”开始使用。')
PY
