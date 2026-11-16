#!/usr/bin/env python3
"""同一组生成表格链接 main / 当前内核；差异必须有独立期望和明确原因，产物只留临时目录。"""
import argparse
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--base', default='origin/main')
parser.add_argument('--output', type=Path, help='临时输出目录；省略则自动创建')
args = parser.parse_args()
out = args.output or Path(tempfile.mkdtemp(prefix='skysheet-table-layouts-'))
out.mkdir(parents=True, exist_ok=True)
base = out / 'baseline'
base.mkdir(exist_ok=True)


def run(command, label):
    with (out / (label + '.log')).open('w') as log:
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit(f'{label} failed ({result.returncode}); see {out / (label + ".log")}')


# 不读工作簿、用户文件或 SampleData；只从指定 Git 提交导出编译内核所需的源码。
archive = subprocess.check_output(['git', 'archive', args.base, 'Package.swift', 'Sources'], cwd=ROOT)
archive_path = out / 'baseline.tar'
archive_path.write_bytes(archive)
with tarfile.open(archive_path) as tar:
    tar.extractall(base, filter='data')
run(['nice', '-n', '10', 'swift', 'build', '--arch', 'arm64', '--package-path', str(base), '--target', 'SkySheetCore'], 'build-base')
run(['nice', '-n', '10', 'swift', 'build', '--arch', 'arm64'], 'build-current')
entry = out / 'main.swift'
entry.write_text('import Foundation\ntry dumpTableLayoutSnapshots()\n')
sources = [ROOT / 'Sources/SkySheetChecks' / name for name in ['Harness.swift', 'EngineHarness.swift', 'TableLayoutChecks.swift']]
for label, folder in [('base', base), ('current', ROOT)]:
    build = folder / '.build/arm64-apple-macosx/debug'
    command = ['nice', '-n', '10', 'swiftc', '-target', 'arm64-apple-macosx15.0', '-swift-version', '6',
               '-I', str(build / 'Modules')]
    if label == 'base':
        command += ['-DTABLE_LAYOUT_BASELINE']
    command += [str(p) for p in sources + [entry]]
    command += [str(p) for p in sorted((build / 'SkySheetCore.build').glob('*.o'))]
    command += ['-o', str(out / label)]
    run(command, 'compile-' + label)
    run([str(out / label)], label)
    (out / (label + '.json')).write_text((out / (label + '.log')).read_text())

before = json.loads((out / 'base.json').read_text())
after = json.loads((out / 'current.json').read_text())
assert [x['name'] for x in before] == [x['name'] for x in after]
differences = []
for old, new in zip(before, after):
    changed = [key for key in new if new[key] != old[key]]
    if not changed:
        continue
    reason = new['improvement']
    if changed == ['note'] or set(changed) == {'note'}:
        reason = '疑似合计仅作不确定提示，明确行号且说明保留数据；main 没有提示。'
    if reason is None:
        raise SystemExit(f'Unexplained difference: {new["name"]}: {changed}; see {out}')
    differences.append({'name': new['name'], 'fields': changed, 'why': reason})
(out / 'differences.json').write_text(json.dumps(differences, ensure_ascii=False, indent=2))
# 先跑当前版本对已知数据的硬断言，不能用“有解释”掩盖错误统计。
run([str(ROOT / '.build/arm64-apple-macosx/debug/SkySheetChecks'), '--table-blocks'], 'checks')
print(json.dumps({'base': subprocess.check_output(['git', 'rev-parse', args.base], cwd=ROOT, text=True).strip(),
                  'cases': len(after), 'same': len(after) - len(differences), 'intentional_differences': len(differences),
                  'output': str(out)}, ensure_ascii=False))
