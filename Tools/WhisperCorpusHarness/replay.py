#!/usr/bin/env python3
"""Offline installed-model comparison; all generated files stay in the output folder."""
import argparse
import hashlib
import platform
import json
import pathlib
import shutil
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--model-root', required=True)
p.add_argument('--corpus', required=True)
p.add_argument('--build-cache', required=True, help='Existing resolved SwiftPM .build directory')
p.add_argument('--out', required=True)
a = p.parse_args()
repo = pathlib.Path(__file__).resolve().parents[2]
out = pathlib.Path(a.out).resolve()
out.mkdir(parents=True, exist_ok=True)
assert not (out / 'commands.json').exists(), 'Use a fresh output directory to preserve prior runs'
(out / 'environment.json').write_text(json.dumps({
  'platform': platform.platform(), 'arguments': vars(a),
  'batchRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
}, indent=2))
profile = out / 'offline.sb'
profile.write_text('(version 1) (allow default) (deny network*)\n')
commands = []
def run(cmd, log, acceptable=(0,)):
  commands.append(cmd)
  (out / 'commands.json').write_text(json.dumps(commands, indent=2))
  with open(out / log, 'w') as f:
    result = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, cwd=repo)
  if result.returncode not in acceptable:
    raise RuntimeError(f'{log}: exit {result.returncode}')
for variant in ['batch', 'rolling']:
  package = out / (variant + '-source')
  shutil.copytree(repo / 'Tools/WhisperCorpusHarness', package, ignore=shutil.ignore_patterns('.build', '__pycache__'), symlinks=False, dirs_exist_ok=True)
  if variant == 'batch':
    source = subprocess.check_output(['git', 'show', 'HEAD:Talkify/Whisper/WhisperRecognizer.swift'], cwd=repo)
    assert b'refreshDraft' not in source, 'HEAD is no longer the batch baseline; pin a batch revision explicitly'
    (package / 'Sources/WhisperCorpusHarness/Talkify/Whisper/WhisperRecognizer.swift').write_bytes(source)
  run(['swift', 'build', '--package-path', str(package), '--scratch-path', a.build_cache,
       '--disable-automatic-resolution', '--skip-update', '-c', 'release'], variant + '-build.log')
  binpath = subprocess.check_output(['swift', 'build', '--package-path', str(package), '--scratch-path', a.build_cache,
                                    '-c', 'release', '--show-bin-path'], cwd=repo, text=True).strip()
  binary = out / (variant + '-harness')
  shutil.copy2(pathlib.Path(binpath) / 'WhisperCorpusHarness', binary)
  run(['/usr/bin/sandbox-exec', '-f', str(profile), str(binary), a.model_root, a.corpus,
       str(out / variant), '--replay'], variant + '-run.log')
# Existing corpus gate is unpaced by design; its positive-control connection is denied by sandbox.
run(['/usr/bin/sandbox-exec', '-f', str(profile), str(out / 'rolling-harness'),
     str(pathlib.Path(a.model_root) / 'whisper-large-v3-turbo-coreml/fb60b40db48b455d'), a.corpus,
     str(out / 'corpus'), '--expect-network-denied'], 'corpus-run.log', (0, 1))
rows = {v: [json.loads(line) for line in (out / v / 'replay.jsonl').read_text().splitlines()] for v in ['batch', 'rolling']}
assert len(rows['batch']) == len(rows['rolling']) == 6
comparison = []
for b, r in zip(rows['batch'], rows['rolling']):
  assert (b['case'], b['repetition']) == (r['case'], r['repetition'])
  times = [d['seconds'] for d in r['drafts']]
  comparison.append({'case': r['case'], 'repetition': r['repetition'], 'sameFinal': b['finalText'] == r['finalText'],
    'firstDraftSeconds': times[0] if times else None,
    'cadenceSeconds': [y-x for x,y in zip(times,times[1:])],
    'batchFinishMs': b['finishMs'], 'rollingFinishMs': r['finishMs']})
(out / 'comparison.json').write_text(json.dumps(comparison, indent=2))
manifest = {str(f.relative_to(out)): hashlib.sha256(f.read_bytes()).hexdigest()
            for f in out.rglob('*') if f.is_file() and f.suffix in ['.json', '.jsonl', '.log', '.swift']}
(out / 'sha256.json').write_text(json.dumps(manifest, indent=2))
print(json.dumps(comparison, indent=2))
