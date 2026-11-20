#!/usr/bin/env python3
"""Bounded macOS execution of the production ZIP adapter and its XCTest suite.

Requires a local checkout of pinned SSZipArchive 2.6.0. No downloads or simulators.
This omits app/cache/UI integration; run verify-ios.sh for those tests.
"""
import argparse
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--zip-checkout', required=True, type=Path)
args = parser.parse_args()
source = args.zip_checkout.resolve()
pin = 'df35718ea19a94e015b91dc4881dee028ce4cdba'
revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
if revision != pin:
    raise SystemExit('SSZipArchive checkout must match pinned revision ' + pin)
if subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--', 'SSZipArchive'], text=True).strip():
    raise SystemExit('Use an unmodified pinned SSZipArchive checkout.')
build = ROOT / 'build/zip-host-regression'
build.mkdir(parents=True, exist_ok=True)
for directory in ['objects', 'modules/ZipArchive']:
    (build / directory).mkdir(parents=True, exist_ok=True)
local = build / 'SSZipArchive'
shutil.copytree(source / 'SSZipArchive', local, dirs_exist_ok=True)
(build / 'modules/ZipArchive/module.modulemap').write_text(
    f'module ZipArchive {{ umbrella header "{local}/include/ZipArchive.h" export * }}\n')
# ArchiveImportTypes references this app model, which the ZIP adapter does not use.
(build / 'stubs.swift').write_text('import Foundation\nstruct ArchivePreparedPage {}\n')
developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
platform = developer / 'Platforms/MacOSX.platform/Developer'
flags = ['-DHAVE_ARC4RANDOM_BUF', '-DHAVE_INTTYPES_H', '-DHAVE_PKCRYPT', '-DHAVE_STDINT_H',
         '-DHAVE_WZAES', '-DHAVE_ZLIB', '-DZLIB_COMPAT', '-O1']
objects = []
# Serial compilation; regression fixtures are at most 128 KiB, with injected tiny limits.
for path in sorted((local / 'minizip').glob('*.c')) + [local / 'SSZipArchive.m']:
    obj = build / 'objects' / (path.stem + '.o')
    objects.append(str(obj))
    command = ['xcrun', 'clang', *flags, '-c', str(path), '-o', str(obj)]
    if path.suffix == '.m':
        command += ['-fobjc-arc', '-fmodules', '-fmodules-cache-path=' + str(build / 'clang-cache')]
    subprocess.run(command, check=True, timeout=60)
test = (ROOT / 'ZipImageViewerTests/ZipExtractorTests.swift').read_text().replace('@testable import ZipImageViewer', '')
(build / 'HostTests.swift').write_text(test)
(build / 'main.swift').write_text('import XCTest\n'
    'let suite = XCTestSuite(forTestCaseClass: ZipExtractorTests.self)\n'
    'suite.run()\nexit(suite.testRun!.hasSucceeded && suite.testRun!.executionCount > 0 ? 0 : 1)\n')
swift = [str(ROOT / 'ZipImageViewer/ArchiveImport' / name) for name in
         ['ArchiveImportTypes.swift', 'ArchiveOutputPolicy.swift', 'ZipMetadataAdmission.swift', 'ZipExtractor.swift']]
command = ['xcrun', 'swiftc', '-I', str(platform / 'usr/lib'), '-L', str(platform / 'usr/lib'),
           '-F', str(platform / 'Library/Frameworks'), '-Xlinker', '-rpath', '-Xlinker', str(platform / 'usr/lib'),
           '-Xlinker', '-rpath', '-Xlinker', str(platform / 'Library/Frameworks'),
           '-module-cache-path', str(build / 'swift-cache'), '-I', str(build / 'modules'),
           '-import-objc-header', str(ROOT / 'ZipImageViewer/ArchiveImport/ZipStreamingBridge.h'),
           str(build / 'stubs.swift'), *swift, str(build / 'HostTests.swift'), str(build / 'main.swift'),
           *objects, '-lz', '-liconv', '-framework', 'Security', '-o', str(build / 'zip-tests')]
subprocess.run(command, check=True, timeout=120)
subprocess.run([str(build / 'zip-tests')], check=True, timeout=60)
print('PASS: ZIP host regression against SSZipArchive ' + pin + '; not an iOS app/simulator run.')
