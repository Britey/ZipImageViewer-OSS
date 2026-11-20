#!/usr/bin/env python3
"""Compiler heap: 512 MiB. Test heap: 128 MiB. Tiny synthetic fixtures only."""
import argparse
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=
    "Run bounded backend JVM tests using cached pinned dependencies; no Gradle daemon, downloads or device.")
parser.add_argument('--gradle-home', type=Path,
                    default=Path(os.environ.get('GRADLE_USER_HOME', str(Path.home() / '.gradle'))))
parser.add_argument('--java-home', type=Path, required=True)
args = parser.parse_args()
cache = args.gradle_home / 'caches/modules-2/files-2.1'


def jars(group, artifact, version):
    found = sorted((cache / group / artifact).glob(version + '/*/*.jar'))
    if not found:
        raise SystemExit('Missing cached dependency: ' + artifact + ' ' + version)
    return found[:1]


compiler = sum((jars(*dependency) for dependency in [
    ('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.2.21'),
    ('org.jetbrains.kotlin', 'kotlin-stdlib', '2.2.21'),
    ('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.2.21'),
    ('org.jetbrains.kotlin', 'kotlin-reflect', '1.6.10'),
    ('org.jetbrains.intellij.deps', 'trove4j', '1.0.20200330'),
    ('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.8.0'),
    ('org.jetbrains', 'annotations', '13.0'),
]), [])
runtime = sum((jars(*dependency) for dependency in [
    ('org.jetbrains.kotlin', 'kotlin-stdlib', '2.2.21'),
    ('org.jetbrains', 'annotations', '13.0'),
    ('junit', 'junit', '4.13.2'),
    ('org.hamcrest', 'hamcrest-core', '1.3'),
    ('net.lingala.zip4j', 'zip4j', '2.11.5'),
]), [])


def classpath(paths):
    return os.pathsep.join(map(str, paths))


root = Path(__file__).resolve().parents[1]
build = root / 'build/backend-jvm-regression'
build.mkdir(parents=True, exist_ok=True)
src = root / 'android/app/src'
files = [src / 'main/java/com/brite/zipimageviewer' / path for path in [
    'data/ArchiveModels.kt', 'data/ArchivePolicy.kt', 'data/ZipMetadataAdmission.kt',
    'reader/ReaderModels.kt', 'reader/ReaderCoverIndex.kt',
]]
files += [src / 'test/java/com/brite/zipimageviewer' / path for path in [
    'data/ZipMetadataAdmissionTest.kt', 'data/ArchivePolicyTest.kt',
    'reader/ReaderCoverIndexTest.kt', 'reader/ReaderModelsTest.kt',
]]
java = str(args.java_home / 'bin/java')
subprocess.run([
    java, '-Xmx512m', '-cp', classpath(compiler), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
    '-no-stdlib', '-no-reflect', '-classpath', classpath(runtime),
    '-d', str(build / 'kotlin-classes'), *map(str, files),
], check=True, timeout=120)
subprocess.run([
    java, '-Xmx128m', '-cp', classpath([build / 'kotlin-classes', *runtime]), 'org.junit.runner.JUnitCore',
    'com.brite.zipimageviewer.data.ZipMetadataAdmissionTest',
    'com.brite.zipimageviewer.data.ArchivePolicyTest',
    'com.brite.zipimageviewer.reader.ReaderCoverIndexTest',
    'com.brite.zipimageviewer.reader.ReaderModelsTest',
], check=True, timeout=60)
