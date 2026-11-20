#!/usr/bin/env python3
"""Exercise the installed shared UI on an explicitly selected disposable emulator.

Does not install, uninstall or clear application data. Start with a fresh
installation to exercise real file-picker import. Use --serial to avoid touching a device.
Release must be installed with a disposable test signature and Metro stopped.
"""
import argparse
from pathlib import Path
import re
import shlex
import subprocess
import time
import xml.etree.ElementTree as ET
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--adb', default='adb')
parser.add_argument('--serial', required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--package', choices=['com.brite.zipimageviewer.debug', 'com.brite.zipimageviewer'],
                    default='com.brite.zipimageviewer.debug')
parser.add_argument('--encrypted-archive', type=Path, action='append', default=[],
                    help='Public test fixture using test-password; imports through the actual system picker')
parser.add_argument('--reload-password', action='store_true',
                    help='Debug only: reload React at each password prompt, then delete the synthetic source before unlocking')
parser.add_argument('--reload-reader', action='store_true', help='Debug only: reload the hidden shared reader without closing its native session')
parser.add_argument('--existing-seed', action='store_true', help='Open a previously seeded archive instead of importing a test-only fixture')
parser.add_argument('--seed-archive', type=Path,
                    default=Path(__file__).resolve().parents[1] / 'android/app/src/androidTest/assets/archive-fixtures/field-notes.cbz',
                    help='Test-only reader fixture imported through the actual system picker')
parser.add_argument('--seed-title', default='Field Notes.cbz', help='Exact title for --existing-seed')
parser.add_argument('--expected-page', type=int)
parser.add_argument('--rotate-reader', action='store_true',
                    help='Exercise landscape tools, native swipes and return to portrait; restore the emulator rotation policy')
parser.add_argument('--verify-double-tap', action='store_true',
                    help='Fresh import only: exercise live shared zoom settings, rapid page taps and restart persistence')
args = parser.parse_args()
if not args.serial.startswith('emulator-'):
    parser.error('This smoke test only runs on disposable emulator serials.')
if args.reload_reader and args.package != 'com.brite.zipimageviewer.debug':
    parser.error('--reload-reader requires Debug and Metro.')
if args.reload_password and (args.package != 'com.brite.zipimageviewer.debug' or not args.encrypted_archive):
    parser.error('--reload-password requires the Debug package and encrypted fixtures, with Metro running.')
if args.verify_double_tap and args.existing_seed:
    parser.error('--verify-double-tap requires a fresh fixture import and default reader preferences.')
args.output.mkdir(parents=True, exist_ok=True)
for archive in args.encrypted_archive + ([] if args.existing_seed else [args.seed_archive]):
    if not archive.is_file() or archive.suffix.lower() not in {'.zip', '.cbz', '.7z'}:
        parser.error(f'Expected an existing test archive: {archive}')


def adb(*command):
    return subprocess.check_output([args.adb, '-s', args.serial, *command], timeout=30)


def tree():
    for _ in range(3):
        output = adb('shell', 'uiautomator', 'dump', '/sdcard/window.xml')
        if b'dumped to:' in output:
            current = ET.fromstring(adb('shell', 'cat', '/sdcard/window.xml'))
            # Fresh emulator profiles show Android's first fullscreen tutorial
            # above the reader. Acknowledge this observed system prompt once.
            if any(n.get('resource-id') == 'android:id/immersive_cling_title' for n in current.iter('node')):
                button = next(n for n in current.iter('node') if n.get('resource-id') == 'android:id/ok')
                tap(button)
                time.sleep(.3)
                continue
            return current
        time.sleep(.3)
    raise AssertionError('UI automation did not return a fresh hierarchy')


def matches(node, identifier):
    value = node.get('resource-id', '')
    return value == identifier or value.endswith('/' + identifier)


def wait_for(predicate, label, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        current = tree()
        found = next((node for node in current.iter('node') if predicate(node)), None)
        if found is not None:
            return found
        time.sleep(.3)
    (args.output / 'failure.xml').write_bytes(ET.tostring(current))
    raise AssertionError(f'Timed out waiting for {label}')


def tap(node):
    values = list(map(int, re.findall(r'\d+', node.attrib['bounds'])))
    left, top, right, bottom = values
    adb('shell', 'input', 'tap', str((left + right) // 2), str((top + bottom) // 2))


def library_target(predicate, label, toward_top=False):
    # Narrow phones and larger fonts put actions below the viewport. Scroll the
    # observed library surface rather than assuming every card fits on screen.
    for _ in range(7):
        current = tree()
        found = next((n for n in current.iter('node') if predicate(n)), None)
        if found is not None:
            return found
        viewport = next((n for n in current.iter('node') if matches(n, 'libraryScreen')), None)
        assert viewport is not None, 'Expected the shared library scroll surface'
        left, top, right, bottom = map(int, re.findall(r'\d+', viewport.attrib['bounds']))
        start = top + (bottom - top) * (0.25 if toward_top else 0.8)
        end = top + (bottom - top) * (0.8 if toward_top else 0.25)
        adb('shell', 'input', 'swipe', str((left + right) // 2), str(int(start)),
            str((left + right) // 2), str(int(end)), '400')
    (args.output / 'failure.xml').write_bytes(ET.tostring(current))
    raise AssertionError(f'Could not scroll to {label}')


def capture(name):
    current = tree()  # Wait for the UI automation idle boundary before the screenshot.
    (args.output / f'{name}.png').write_bytes(adb('exec-out', 'screencap', '-p'))
    (args.output / f'{name}.xml').write_bytes(ET.tostring(current))


def focus_password():
    # Native picker/modal animations can move the field after its first snapshot.
    # Observe focus before sending keystrokes, rather than silently losing input.
    for _ in range(3):
        tap(wait_for(lambda n: matches(n, 'passwordInput'), 'password input'))
        if any(matches(n, 'passwordInput') and n.get('focused') == 'true' for n in tree().iter('node')):
            return
    raise AssertionError('Password field did not receive focus')


def type_password(value):
    # An Activity/IME transition may keep accessibility focus before adb key
    # events reach the editor. Retry only a demonstrably empty field: never
    # append to partially entered text or bypass the exact input assertion.
    for _ in range(3):
        focus_password()
        adb('shell', 'input', 'text', value)
        field = wait_for(lambda n: matches(n, 'passwordInput'), 'password input after typing')
        entered = len(field.get('text', ''))
        if entered == len(value):
            return
        assert entered == 0, 'Synthetic password was only partially entered'
    raise AssertionError('Synthetic password input did not arrive')


def wait_absent(identifier, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not any(matches(n, identifier) for n in tree().iter('node')):
            return
    raise AssertionError(f'{identifier} remained visible')


def reader_page(page):
    return wait_for(lambda n: matches(n, 'readerPageButton') and f'Current page {page} of ' in n.get('content-desc', ''), f'shared reader page {page}')


def zoom_toggle(enabled):
    return wait_for(lambda n: n.get('content-desc') == 'Double-tap to zoom' and
                    n.get('checked') == str(enabled).lower(), f'double-tap setting {enabled}')


def exercise_double_tap_setting():
    def close_settings(page):
        tap(wait_for(lambda n: matches(n, 'readerSettingsDone'), 'close zoom settings'))
        wait_absent('readerSettingsDone')
        reader_page(page)  # The native modal must return touch ownership to the reader.

    tap(wait_for(lambda n: matches(n, 'readerSettings'), 'reader settings for zoom'))
    tap(zoom_toggle(True))
    zoom_toggle(False)
    close_settings(2)
    canvas = wait_for(lambda n: matches(n, 'readerCanvas'), 'native gesture canvas')
    left, top, right, bottom = map(int, re.findall(r'\d+', canvas.attrib['bounds']))
    x, y = left + (right - left) * 9 // 10, top + (bottom - top) * 35 // 100

    def double_tap():
        # One device-side invocation keeps the two real input taps within the
        # recognizer's double-tap window without host subprocess latency.
        # Keep an explicit gap above Android's minimum double-tap interval.
        adb('shell', f'input tap {x} {y}; sleep 0.08; input tap {x} {y}')

    double_tap()
    reader_page(4)  # Starting at page 2: disabled zoom must deliver both taps.
    capture('double-tap-disabled-rapid-pages')
    tap(wait_for(lambda n: matches(n, 'readerSettings'), 'reenable live zoom'))
    tap(zoom_toggle(False))
    zoom_toggle(True)
    close_settings(4)
    double_tap()
    reader_page(4)  # Enabled zoom-in consumes the double tap without paging.
    capture('double-tap-enabled-zoom-in')
    double_tap()
    reader_page(4)  # Zoom-out must also keep the page.
    adb('shell', 'input', 'tap', str(x), str(y))
    reader_page(5)  # A normal page tap works again after zoom-out.
    tap(wait_for(lambda n: matches(n, 'readerSettings'), 'disable zoom before restart'))
    tap(zoom_toggle(True))
    zoom_toggle(False)
    close_settings(5)
    tap(wait_for(lambda n: matches(n, 'readerPages'), 'restore page two using overview'))
    tap(wait_for(lambda n: matches(n, 'thumbnail_1'), 'page two thumbnail'))
    reader_page(2)


def exercise_reader_rotation():
    policy = adb('shell', 'wm', 'user-rotation').decode().strip().split()
    assert policy == ['free'] or (len(policy) == 2 and policy[0] == 'lock' and policy[1] in '0123'), 'Unknown emulator rotation policy'
    sizes = re.findall(r'(?:Physical|Override) size: (\d+)x(\d+)', adb('shell', 'wm', 'size').decode())
    assert sizes, 'Missing emulator display dimensions'
    natural_width, natural_height = map(int, sizes[-1])
    landscape = '0' if natural_width > natural_height else '1'
    portrait = '1' if natural_width > natural_height else '0'

    def bounds(node):
        return list(map(int, re.findall(r'\d+', node.attrib['bounds'])))

    def canvas_is_landscape(node):
        left, top, right, bottom = bounds(node)
        return matches(node, 'readerCanvas') and right - left > bottom - top

    try:
        adb('shell', 'wm', 'user-rotation', 'lock', landscape)
        canvas = wait_for(canvas_is_landscape, 'landscape native canvas')
        reader_page(2)
        tap(wait_for(lambda n: matches(n, 'readerPages'), 'landscape Pages'))
        thumbnail = wait_for(lambda n: matches(n, 'thumbnail_2'), 'landscape overview thumbnail')
        left, top, right, bottom = bounds(canvas)
        x0, y0, x1, y1 = bounds(thumbnail)
        assert left <= x0 < x1 <= right and top <= y0 < y1 <= bottom, 'Landscape thumbnail extends outside the window'
        capture('reader-overview-landscape')
        adb('shell', 'input', 'keyevent', '4')
        reader_page(2)
        # Actual canvas gestures exercise empty-space touch routing through the
        # shared SafeAreaProvider after the tools have been dismissed.
        y = str((top + bottom) // 2)
        x_start = str(left + (right - left) * 3 // 4)
        x_end = str(left + (right - left) // 4)
        adb('shell', 'input', 'swipe', x_start, y, x_end, y, '400')
        reader_page(3)
        capture('reader-landscape-native-swipe')
        adb('shell', 'input', 'swipe', x_end, y, x_start, y, '400')
        reader_page(2)
        adb('shell', 'wm', 'user-rotation', 'lock', portrait)
        wait_for(lambda n: matches(n, 'readerCanvas') and bounds(n)[2] - bounds(n)[0] < bounds(n)[3] - bounds(n)[1], 'portrait native canvas')
        reader_page(2)
        capture('reader-portrait-after-rotation')
    finally:
        adb('shell', 'wm', 'user-rotation', *policy)


def exercise_reader():
    wait_for(lambda n: matches(n, 'readerPageButton'), 'shared reader chrome', timeout=90)
    tap(wait_for(lambda n: matches(n, 'readerPages'), 'shared Pages'))
    wait_for(lambda n: matches(n, 'thumbnail_2'), 'native overview thumbnail')
    capture('reader-overview')
    tap(wait_for(lambda n: matches(n, 'thumbnail_2'), 'page three'))
    reader_page(3)
    tap(wait_for(lambda n: matches(n, 'readerPageButton'), 'shared jump'))
    field = wait_for(lambda n: matches(n, 'pageNumberInput'), 'shared page input')
    tap(field)
    adb('shell', 'input', 'keyevent', '67')
    adb('shell', 'input', 'text', '2')
    wait_for(lambda n: matches(n, 'pageNumberInput') and n.get('text') == '2', 'exact jump input')
    adb('shell', 'input', 'keyevent', '4')
    tap(wait_for(lambda n: matches(n, 'confirmPageJump'), 'confirm shared jump'))
    reader_page(2)
    tap(wait_for(lambda n: matches(n, 'readerSettings'), 'shared reader settings'))
    wait_for(lambda n: n.get('text') == 'Reader settings', 'reader settings title')
    capture('reader-settings')
    tap(wait_for(lambda n: matches(n, 'readerSettingsDone'), 'close reader settings'))
    if args.verify_double_tap:
        exercise_double_tap_setting()
    if args.rotate_reader:
        exercise_reader_rotation()
    tap(wait_for(lambda n: matches(n, 'readerHide'), 'hide shared chrome'))
    wait_absent('readerClose')
    capture('reader-hidden')
    if args.reload_reader:
        before_pid = adb('shell', 'pidof', args.package).strip()
        adb('shell', 'am', 'broadcast', '-a', args.package + '.RELOAD_APP_ACTION', '-p', args.package)
        wait_for(lambda n: matches(n, 'readerCanvas'), 'reattached native canvas', timeout=90)
        wait_absent('readerClose')
        assert before_pid == adb('shell', 'pidof', args.package).strip(), 'Reader reload restarted native process'
        capture('reader-reloaded-hidden')
    adb('shell', 'input', 'keyevent', '4')
    reader_page(2)  # Back reveals controls before closing.
    capture('reader-page-two')


def choose_system_archive(name, *, empty=False):
    # Respect a saved picker preference by using the one-time override.
    # Fresh empty-library runs exercise the replacement action itself.
    tap(library_target(lambda n: matches(n, 'openEmptyArchive' if empty else 'pickArchiveOnce'),
                       'empty-library Open archive' if empty else 'one-time file picker', toward_top=not empty))
    if not empty:
        tap(wait_for(lambda n: n.get('text') == 'System files', 'one-time System files'))
    tap(wait_for(lambda n: n.get('content-desc') == 'Show roots', 'system picker roots'))
    tap(wait_for(lambda n: n.get('text') == 'Downloads' and n.get('resource-id') == 'android:id/title',
                 'Downloads drawer location'))
    tap(wait_for(lambda n: n.get('content-desc') == 'Search', 'provider search'))
    wait_for(lambda n: matches(n, 'search_src_text') and n.get('focused') == 'true', 'provider search input')
    adb('shell', 'input', 'text', name)
    adb('shell', 'input', 'keyevent', '66')
    tap(wait_for(lambda n: n.get('text') == name and n.get('class') == 'android.widget.TextView',
                 'test fixture search result'))


seed_title = args.seed_title if args.existing_seed else f'Field-Notes-{uuid.uuid4().hex[:10]}.cbz'
package = args.package
adb('shell', 'am', 'start', '-W', '-n', package + '/com.brite.zipimageviewer.MainActivity')
wait_for(lambda n: matches(n, 'openSettings'), 'shared library')
capture('library')
tap(wait_for(lambda n: matches(n, 'openSettings'), 'Settings button'))
wait_for(lambda n: matches(n, 'settingsScreen'), 'shared settings')
capture('settings')
adb('shell', 'input', 'keyevent', '4')
if args.existing_seed:
    # Search first: Fabric can flatten card children into unrelated siblings.
    # Refuse an ambiguous result rather than tapping another archive's Resume.
    tap(wait_for(lambda n: matches(n, 'searchArchives'), 'library search'))
    adb('shell', 'input', 'text', seed_title.replace(' ', '%s'))
    adb('shell', 'input', 'keyevent', '4')
    library_target(lambda n: n.get('text') == seed_title, 'seeded Field Notes title')
    library_target(lambda n: n.get('content-desc') == 'Resume reading', 'seeded resume action')
    candidates = list(tree().iter('node'))
    assert sum(n.get('content-desc') == 'Details' for n in candidates) == 1, 'Seed search is ambiguous'
    actions = [n for n in candidates if n.get('content-desc') == 'Resume reading']
    assert len(actions) == 1, 'Seeded archive has no unique Resume action'
    tap(actions[0])
else:
    # Cancellation must leave the recurring empty-library action available.
    for attempt in range(2):
        tap(library_target(lambda n: matches(n, 'openEmptyArchive'), 'empty-library Open archive'))
        wait_for(lambda n: n.get('content-desc') == 'Show roots', 'real system picker')
        adb('shell', 'input', 'keyevent', '4')
        wait_for(lambda n: matches(n, 'openEmptyArchive') and n.get('enabled') == 'true', 'empty library after cancel')
        capture(f'empty-library-after-cancel-{attempt}')
    adb('push', str(args.seed_archive.resolve()), '/sdcard/Download/' + seed_title)
    choose_system_archive(seed_title, empty=True)
wait_for(lambda n: matches(n, 'readerPageButton'), 'shared reader', timeout=90)
if args.expected_page:
    wait_for(lambda n: f'Current page {args.expected_page} of ' in n.get('content-desc', ''), 'restored original page')
capture('reader')
exercise_reader()
adb('shell', 'input', 'keyevent', '4')
wait_for(lambda n: matches(n, 'openSettings'), 'return to shared library')
library_target(lambda n: seed_title in n.get('text', ''), 'retained fixture archive')
capture('library-after-import')
adb('shell', 'am', 'force-stop', package)
adb('shell', 'am', 'start', '-W', '-n', package + '/com.brite.zipimageviewer.MainActivity')
wait_for(lambda n: matches(n, 'openSettings'), 'shared library after process restart')
library_target(lambda n: seed_title in n.get('text', ''), 'retained library after process restart')
capture('library-after-restart')
tap(library_target(lambda n: n.get('content-desc') == 'Resume reading', 'saved reader resume'))
reader_page(2)
capture('reader-after-restart')
adb('shell', 'input', 'keyevent', '4')
wait_for(lambda n: matches(n, 'openSettings'), 'library after resumed reader close')
if args.verify_double_tap:
    tap(wait_for(lambda n: matches(n, 'openSettings'), 'persisted shared library settings'))
    wait_for(lambda n: matches(n, 'settingsScreen'), 'library settings after restart')
    zoom_toggle(False)
    capture('double-tap-disabled-after-restart')
    adb('shell', 'input', 'keyevent', '4')
run_id = uuid.uuid4().hex[:10]
for index, archive in enumerate(args.encrypted_archive):
    # Synthetic fixture copies only; filenames are unique within this run.
    name = f'mvp-smoke-{run_id}-{index}{archive.suffix.lower()}'
    adb('push', str(archive.resolve()), '/sdcard/Download/' + name)
    choose_system_archive(name)
    field = wait_for(lambda n: matches(n, 'passwordInput'), 'shared secure password prompt')
    capture(f'encrypted-{index}-password')
    if args.reload_password:
        type_password('discard-on-reload')
        adb('shell', 'input', 'keyevent', '4')
        wait_for(lambda n: matches(n, 'passwordInput') and bool(n.get('text')), 'typed ephemeral password')
        before_pid = adb('shell', 'pidof', package).strip()
        # RN 0.86's DevSupportManagerBase registers this actual reload receiver.
        adb('shell', 'am', 'broadcast', '-a', package + '.RELOAD_APP_ACTION', '-p', package)
        field = wait_for(lambda n: matches(n, 'passwordInput') and not n.get('text'),
                         'remounted password prompt with cleared JS input', timeout=90)
        assert before_pid and adb('shell', 'pidof', package).strip() == before_pid, 'Reload restarted the native process'
        adb('shell', 'rm', '--', shlex.quote('/sdcard/Download/' + name))
        capture(f'encrypted-{index}-after-reload')
    type_password('test-password')
    adb('shell', 'input', 'keyevent', '4')  # Dismiss keyboard, retaining the password modal.
    tap(wait_for(lambda n: matches(n, 'submitPassword'), 'Unlock archive'))
    wait_for(lambda n: matches(n, 'readerPageButton'), 'unlocked shared reader', timeout=90)
    capture(f'encrypted-{index}-reader')
    adb('shell', 'input', 'keyevent', '4')
    wait_for(lambda n: matches(n, 'openSettings'), 'shared library after encrypted import')
    library_target(lambda n: name in n.get('text', ''), 'retained encrypted archive')
    capture(f'encrypted-{index}-library')
print('PASS: shared library/settings, native canvas and shared reader tools, return and page-2 resume after process restart')
if args.verify_double_tap:
    print('PASS: default-on shared double-tap zoom, live disable/enable, two rapid page taps, zoom-in/out and persisted disable after process restart')
if args.rotate_reader:
    print('PASS: landscape overview, native canvas swipes through shared chrome and portrait page preservation; rotation policy restored')
if args.encrypted_archive:
    print(f'PASS: {len(args.encrypted_archive)} system-picker imports through shared password UI and native reader ({package})')
if args.reload_password:
    print('PASS: real React reload cleared ephemeral password input without restarting the process; unlock used staged bytes after synthetic source deletion')
