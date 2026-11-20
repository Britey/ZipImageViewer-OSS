#!/usr/bin/env python3
"""Validate Swift grammar, Xcode resources, dependency pins and fixture integrity."""
import base64
import hashlib
import io
import json
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

from pbxproj import XcodeProject
from tree_sitter import Language, Parser
import tree_sitter_swift

ROOT = Path(__file__).resolve().parents[1]
parser = Parser(Language(tree_sitter_swift.language()))
checks = 0


def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message)
    checks += 1


def parse_swift(source):
    # tree-sitter-swift 0.7.3 rejects UIKit's valid typed closure parameter
    # `{ (self: SomeViewController, _) in ... }` used by registerForTraitChanges.
    # Rename ONLY that parameter for grammar parsing; keep every other byte,
    # including the body, so unrelated syntax errors still fail normally.
    # The same-length name preserves source offsets. Native Swift compilation
    # remains the authority for parameter binding and type correctness.
    grammar_source = re.sub(
        rb'(\{\s*\()self(?=\s*:\s*[A-Za-z_][A-Za-z_0-9]*\s*,\s*_\s*\)\s*in\b)',
        rb'\1this', source)
    return parser.parse(grammar_source)

def main():
    swift_files = sorted(p for folder in ['ZipImageViewer', 'ZipImageViewerTests', 'ZipImageViewerUITests']
                         for p in (ROOT / folder).rglob('*.swift'))
    all_swift = '\n'.join(p.read_text() for p in swift_files)
    for path in swift_files:
        tree = parse_swift(path.read_bytes())
        check(not tree.root_node.has_error, f'Swift grammar error: {path}')
    print(f'PASS: Swift syntax parsed in {len(swift_files)} files (no type checking).')

    project_path = ROOT / 'ZipImageViewer.xcodeproj/project.pbxproj'
    project = XcodeProject.load(str(project_path))
    check(len(project.objects.get_objects_in_section('PBXNativeTarget')) == 3, 'Missing Xcode target')
    raw_project = project_path.read_text()
    definitions = set(re.findall(r'^\s*([A-F0-9]{24})[^\n]*? = \{', raw_project, re.M))
    references = set(re.findall(r'\b[A-F0-9]{24}\b', raw_project))
    check(references <= definitions, f'Dangling Xcode references: {references - definitions}')
    groups = project.objects.get_objects_in_section('PBXFileSystemSynchronizedRootGroup')
    for folder in ['ZipImageViewer', 'ZipImageViewerTests', 'ZipImageViewerUITests']:
        check(any(g.path == folder for g in groups), f'Missing synchronized source group: {folder}')
    check('ArchiveService.swift' not in raw_project, 'Unexpected explicit new source membership')
    # Validate repository resources, not ignored native build products or package
    # checkouts. NUL separators preserve filenames containing whitespace.
    tracked_files = subprocess.check_output(
        ['git', 'ls-files', '-z'], cwd=ROOT, text=True).split('\0')
    for filename in filter(None, tracked_files):
        path = ROOT / filename
        if not path.is_file():
            continue
        if path.suffix in ('.plist', '.xcsettings'):
            plistlib.loads(path.read_bytes())
            check(True, f'Invalid plist: {path}')
        elif path.suffix in ('.storyboard', '.xcworkspacedata'):
            tree = ET.parse(path)
            check(tree.getroot() is not None, f'Invalid XML: {path}')
        elif path.name in ('Contents.json', 'Package.resolved'):
            data = json.loads(path.read_text())
            for item in data.get('images', []):
                if 'filename' in item:
                    check((path.parent / item['filename']).is_file(), f'Missing asset: {item}')
    for name in re.findall(r'INFOPLIST_KEY_UI(?:Launch|Main)StoryboardFile = ([^;]+);', raw_project):
        check((ROOT / f'ZipImageViewer/Base.lproj/{name}.storyboard').is_file(), f'Missing storyboard: {name}')
    for name in re.findall(r'INFOPLIST_KEY_UILaunchStoryboardName = ([^;]+);', raw_project):
        check((ROOT / f'ZipImageViewer/Base.lproj/{name}.storyboard').is_file(), f'Missing launch storyboard: {name}')
    for path in ROOT.glob('ZipImageViewer/**/*.storyboard'):
        tree = ET.parse(path)
        ids = {n.attrib['id'] for n in tree.iter() if 'id' in n.attrib}
        for node in tree.iter():
            if 'destination' in node.attrib:
                check(node.attrib['destination'] in ids, f'Dangling storyboard destination: {path}')
            if node.tag == 'action':
                name = node.attrib['selector'].split(':')[0]
                check(re.search(r'@IBAction\s+private func\s+' + name + r'\b', all_swift), f'Missing action: {name}')
            if node.tag == 'outlet':
                name = node.attrib['property']
                check(re.search(r'@IBOutlet\s+private weak var\s+' + name + r'\b', all_swift), f'Missing outlet: {name}')
            if 'customClass' in node.attrib and node.attrib['customClass'] != 'UIResponder':
                check('class ' + node.attrib['customClass'] in all_swift, 'Missing storyboard class')
    print('PASS: Xcode object graph, source groups, plists, assets, storyboard resources and connections.')

    components = {
        'ReaderPreferences.swift': 'ReaderPreferences',
        'ReaderPreferencesStore.swift': 'ReaderPreferencesStore',
        'SettingsViewController.swift': 'SettingsViewController',
        'TapAreaPickerViewController.swift': 'TapAreaPickerViewController',
    }
    for filename, name in components.items():
        path = ROOT / 'ZipImageViewer' / filename
        check(path.is_file(), f'Missing reader settings component: {filename}')
        check(re.search(r'\b(?:struct|class)\s+' + name + r'\b', path.read_text()),
              f'Missing typed settings declaration: {name}')
    for filename in ['ReaderPreferencesTests.swift', 'SettingsInteractionTests.swift']:
        check((ROOT / 'ZipImageViewerTests' / filename).is_file(),
              f'Missing native settings regression suite: {filename}')
    resolved_path = 'ZipImageViewer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    pins = {pin['identity']: pin for pin in json.loads((ROOT / resolved_path).read_text())['pins']}
    check(set(pins) == {'ziparchive', 'zipfoundation'}, 'Unexpected remote dependency set')
    check(pins['ziparchive']['state'] == {
        'version': '2.6.0', 'revision': 'df35718ea19a94e015b91dc4881dee028ce4cdba'
    }, 'SSZipArchive pin changed')
    check(pins['zipfoundation']['state'] == {
        'version': '0.9.20', 'revision': '22787ffb59de99e5dc1fbfe80b19c97a904ad48d'
    }, 'ZIPFoundation pin changed')
    check('relativePath = Vendor/PLzmaSDK;' in raw_project, 'Missing local decoder package')
    for line in (ROOT / 'Vendor/PLzmaSDK/SHA256SUMS').read_text().splitlines():
        digest, path = line.split('  ', 1)
        check(hashlib.sha256((ROOT / 'Vendor/PLzmaSDK' / path).read_bytes()).hexdigest() == digest,
              f'Vendored decoder checksum mismatch: {path}')
    fixture_root = ROOT / 'ZipImageViewerTests/Fixtures/SevenZip'
    fixtures_manifest = json.loads((fixture_root / 'manifest.json').read_text())
    for fixture in fixtures_manifest['fixtures']:
        check(hashlib.sha256((fixture_root / fixture['file']).read_bytes()).hexdigest() == fixture['archive_sha256'],
              f'Archive fixture checksum mismatch: {fixture["file"]}')
    print('PASS: Typed settings components, ZIP dependency pins, decoder and fixture checksums.')

    test_source = (ROOT / 'ZipImageViewerTests/ZipImageViewerTests.swift').read_text()
    fixtures = re.findall(r'private static let (\w+) = Data\(base64Encoded: "([^"]+)"\)', test_source)
    check(len(fixtures) == 3, 'Expected three archive fixtures')
    contents = {}
    raw = {}
    for name, encoded in fixtures:
        raw[name] = base64.b64decode(encoded, validate=True)
        with zipfile.ZipFile(io.BytesIO(raw[name])) as archive:
            check(archive.testzip() is None, f'Invalid ZIP fixture: {name}')
            contents[name] = {n: archive.read(n) for n in archive.namelist()}
    check(contents['imageZIP'] == {'chapter/1.jpg': b'page-a'}, 'Fixture A mismatch')
    check(contents['changedImageZIP'] == {'chapter/1.jpg': b'page-b'}, 'Fixture B mismatch')
    check(len(raw['imageZIP']) == len(raw['changedImageZIP']), 'Same-size regression precondition')
    check(contents['textZIP'] == {'readme.txt': b'no images'}, 'No-images fixture mismatch')
    print('PASS: Embedded ZIP fixture integrity and same-size/different-content preconditions.')

    subprocess.run(['git', 'diff', '--check'], cwd=ROOT, check=True)
    print(f'PASS: {checks} static assertions. Native builds, Swift tests and runtime behavior require separate validation.')


if __name__ == '__main__':
    main()
