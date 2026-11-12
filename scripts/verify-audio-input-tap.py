#!/usr/bin/env python3
"""Opt-in production-source capture regression. Never saves PCM or changes OS routes.

Stop other Talkify capture owners before --capture. An optional stale snapshot is
fault injection, not a physical Bluetooth test. All artifacts remain in .verification.
"""
import argparse
from pathlib import Path
import subprocess


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('--capture', action='store_true', required=True)
  parser.add_argument('--uid', required=True)
  parser.add_argument('--stale-snapshot', action='store_true')
  parser.add_argument('--source', type=Path, help='Preserved baseline MicrophoneInput.swift')
  parser.add_argument('--label', default='tap-regression')
  args = parser.parse_args()
  if not args.label.replace('-', '').replace('_', '').isalnum():
    parser.error('--label must contain only letters, digits, hyphens or underscores')
  root = Path(__file__).resolve().parents[1]
  work = root / '.verification' / args.label
  work.mkdir(parents=True, exist_ok=True)
  source = (args.source or root / 'Talkify/Dictation/MicrophoneInput.swift').read_text()
  anchor = '    let hardwareFormat = inputNode.inputFormat(forBus: 0)'
  assert source.count(anchor) == 1, 'Hardware snapshot seam changed; review instrumentation'
  snapshot = '''    let observed = inputNode.inputFormat(forBus: 0)
    FileHandle.standardError.write(Data("AUDIO-DIAG input=\\(observed) output=\\(inputNode.outputFormat(forBus: 0))\\n".utf8))
'''
  if args.stale_snapshot:
    snapshot += '''    let hardwareFormat = AVAudioFormat(standardFormatWithSampleRate:
      observed.sampleRate == 48_000 ? 24_000 : 48_000, channels: observed.channelCount)!
'''
  else:
    snapshot += '    let hardwareFormat = observed\n'
  source = source.replace(anchor, snapshot.rstrip())
  binding = '      guard status == noErr else { throw InputError.routingFailed(status) }'
  assert source.count(binding) == 1, 'Binding seam changed; review instrumentation'
  source = source.replace(binding, binding + '''
      var bound: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      let readback = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0, &bound, &size)
      FileHandle.standardError.write(Data("AUDIO-DIAG requested=\\(deviceID) bound=\\(bound) status=\\(readback)\\n".utf8))
      guard readback == noErr, bound == deviceID else { throw InputError.unavailable }
''')
  receive = '    publishLevel(of: buffer, generation: generation)'
  assert source.count(receive) == 1, 'Buffer seam changed; review instrumentation'
  source = source.replace(receive, '''    FileHandle.standardError.write(Data("AUDIO-DIAG buffer rate=\\(buffer.format.sampleRate) channels=\\(buffer.format.channelCount) frames=\\(buffer.frameLength)\\n".utf8))
''' + receive)
  copied = work / 'MicrophoneInput.swift'
  copied.write_text(source)
  shared = [root / 'Talkify/AudioInput' / name for name in [
    'AudioInputSelection.swift', 'AudioInputRoute.swift', 'CoreAudioInputDevices.swift',
    'AudioInputLevelMonitor.swift']]
  binary = work / 'probe'
  with (work / 'compile.log').open('w') as log:
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
      str(root / 'scripts/AudioInputProbe.swift'), *map(str, shared), str(copied),
      str(root / 'Talkify/App/AppLog.swift'), '-o', str(binary)],
      stdout=log, stderr=subprocess.STDOUT, check=True)
  with (work / 'capture.log').open('w') as log:
    subprocess.run([str(binary), '--capture', '--uid', args.uid],
      stdout=log, stderr=subprocess.STDOUT, timeout=100, check=True)
  print(f'Capture passed; diagnostics: {work / "capture.log"}')
  print(f'Stale snapshot injected: {args.stale_snapshot}; no physical reconnect claimed')


if __name__ == '__main__':
  main()
