"""Prepare or build the AMLC package. Source files are copied unchanged."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


def digest(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def json_bytes(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + '\n').encode('utf-8')


def load_inputs(root, sync=None, draft=False):
    metadata_path = root / 'metadata.json'
    if not metadata_path.exists():
        metadata_path = root / 'metadata.draft.json'
    raw = metadata_path.read_bytes()
    require(not raw.startswith(b'\xef\xbb\xbf'), 'metadata.json must not have a BOM')
    metadata = json.loads(raw.decode('utf-8'))
    if sync is not None:
        metadata['sync'] = sync
    require(metadata.get('schema_version') == 2, 'schema_version must be 2')
    for field in ('name', 'mod_id', 'author', 'description', 'version', 'game_build', 'homepage'):
        require(isinstance(metadata.get(field), str) and metadata[field].strip(), f'Missing {field}')
    require(re.fullmatch(r'[A-Za-z0-9.]+', metadata['mod_id']), 'Invalid mod_id')
    require(re.fullmatch(r'\d+\.\d+\.\d+', metadata['version']), 'Invalid version')
    require(re.fullmatch(r'\d+\.\d+\.\d+\.\d+', metadata['game_build']), 'Invalid game_build')
    require(metadata.get('enable_ue4ss') is True, 'enable_ue4ss must be true')
    require(metadata['author'] == 'yuexr', 'Unexpected author')
    require(metadata['homepage'] == 'https://yuexr.github.io/astro/mods/mod.html?id=fractal-rose-selector', 'Unexpected homepage')
    require(metadata.get('download') == {
        'type': 'index_file', 'url': 'https://yuexr.github.io/astro/mods/index.json'
    }, 'Unexpected download index')
    allowed_sync = ('none', 'server', 'client', 'serverclient')
    require(metadata.get('sync') in allowed_sync or (draft and metadata.get('sync') is None),
            'sync is undecided. Choose it after multiplayer requirements are confirmed; '
            'use --prepare-only for a non-installable layout draft.')
    mod = root / metadata['mod_id']
    require(mod.is_dir(), f'Missing mod folder: {mod}')
    files = {}
    for source in sorted(mod.rglob('*')):
        require(not source.is_symlink(), f'Symlinks are not supported: {source}')
        if source.is_file() and source.name.lower() != 'enabled.txt':
            files[source.relative_to(mod).as_posix()] = source.read_bytes()
    require('Scripts/main.lua' in files, 'Missing Scripts/main.lua')
    text = files['Scripts/main.lua'].decode('utf-8')
    version = re.search(r"local\s+VERSION\s*=\s*['\"]([^'\"]+)['\"]", text)
    require(version and version[1] == metadata['version'], 'Lua and metadata versions differ')
    return metadata, files


def run(repak, *args):
    result = subprocess.run([str(repak), *map(str, args)], capture_output=True, check=True)
    return result.stdout.decode('utf-8')


def prepare(root, output, sync=None):
    metadata, files = load_inputs(root, sync, draft=True)
    output.mkdir(parents=True, exist_ok=True)
    # This is deliberately not a metadata.json inside a PAK. null is a draft
    # placeholder, not a valid sync mode, and must never reach a release.
    (output / 'metadata.draft.json').write_bytes(json_bytes(metadata))
    payload = output / 'payload'
    expected = {'UE4SS/' + name: data for name, data in files.items()}
    for name, data in expected.items():
        destination = payload / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    actual = {p.relative_to(payload).as_posix(): p.read_bytes()
              for p in payload.rglob('*') if p.is_file()}
    require(actual == expected, 'Draft payload contains unexpected or changed files')
    report = {
        'state': 'draft; sync undecided' if metadata['sync'] is None else 'layout only',
        'mod_id': metadata['mod_id'], 'version': metadata['version'],
        'game_build': metadata['game_build'], 'sync': metadata['sync'],
        'payload_sha256': {name: digest(data) for name, data in expected.items()},
        'expected_extracted_paths': [metadata['mod_id'] + '/' + name for name in files],
        'metadata_valid_for_release': metadata['sync'] is not None,
        'pak_checked': False, 'zip_checked': False,
        'installed': False, 'gameplay_tested': False,
    }
    (output / 'checks.json').write_bytes(json_bytes(report))
    print(f'Prepared layout draft: {output}')
    if metadata['sync'] is None:
        print('No PAK/ZIP created: sync is undecided.')
    return report


def build(root, output, repak, sync=None):
    # Validate before creating anything. No implicit serverclient default.
    metadata, files = load_inputs(root, sync)
    require(repak and repak.is_file(), 'Supply a working --repak executable')
    mod_id, version = metadata['mod_id'], metadata['version']
    pak_name = f'000-{mod_id}-{version}_P.pak'
    zip_name = f'Fractal-Rose-Selector-{version}.zip'
    expected = {'metadata.json': json_bytes(metadata),
                **{'UE4SS/' + name: data for name, data in files.items()}}
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='package-', dir=output) as temporary:
        work = Path(temporary)
        payload = work / 'payload'
        for name, data in expected.items():
            target = payload / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        pak = work / pak_name
        run(repak, 'pack', '--version', 'V8B', '--mount-point', '../../../', payload, pak)
        listing = run(repak, 'list', pak).splitlines()
        require(set(listing) == set(expected) and len(listing) == len(expected), 'Wrong PAK paths')
        unpacked = work / 'unpacked'
        unpacked.mkdir()
        run(repak, 'unpack', pak, '--output', unpacked)
        actual = {p.relative_to(unpacked).as_posix(): p.read_bytes()
                  for p in unpacked.rglob('*') if p.is_file()}
        require(actual == expected, 'PAK round-trip mismatch')
        require(not actual['metadata.json'].startswith(b'\xef\xbb\xbf'), 'Packaged metadata has BOM')
        require(json.loads(actual['metadata.json'].decode('utf-8')) == metadata, 'Metadata differs')
        require(not any(Path(name).name.lower() == 'enabled.txt' for name in actual), 'enabled.txt leaked')
        extracted = work / 'extraction-check' / mod_id
        for name, data in actual.items():
            if name.startswith('UE4SS/'):
                destination = extracted / name[len('UE4SS/'):]
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
        require({p.relative_to(extracted).as_posix(): p.read_bytes()
                 for p in extracted.rglob('*') if p.is_file()} == files, 'Extracted mod differs from source')
        archive = work / zip_name
        with ZipFile(archive, 'w', compression=ZIP_DEFLATED, compresslevel=9) as package:
            info = ZipInfo(pak_name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            package.writestr(info, pak.read_bytes(), compress_type=ZIP_DEFLATED, compresslevel=9)
        with ZipFile(archive) as package:
            require(package.testzip() is None and package.namelist() == [pak_name], 'Invalid ZIP layout')
            require(package.read(pak_name) == pak.read_bytes(), 'ZIP PAK differs')
        report = {
            'state': 'package checks passed; installation and gameplay untested',
            'metadata': metadata, 'pak_name': pak_name, 'zip_name': zip_name,
            'source_sha256': {name: digest(data) for name, data in files.items()},
            'pak_entries': sorted(actual),
            'extracted_paths': [mod_id + '/' + name for name in sorted(files)],
            'pak_sha256': digest(pak.read_bytes()), 'zip_sha256': digest(archive.read_bytes()),
            'installed': False, 'gameplay_tested': False,
        }
        # Publish outputs only after all checks have passed. No game paths used.
        shutil.copyfile(pak, output / pak_name)
        shutil.copyfile(archive, output / zip_name)
        (output / 'checks.json').write_bytes(json_bytes(report))
    print(f'Verified PAK and one-PAK ZIP: {output / zip_name}')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--repak', type=Path)
    parser.add_argument('--output', type=Path, help='Defaults to a separate test-package folder')
    parser.add_argument('--sync', choices=('none', 'server', 'client', 'serverclient'),
                        help='Only choose after multiplayer requirements are established')
    parser.add_argument('--prepare-only', action='store_true', help='Write a layout draft, not a PAK or ZIP')
    args = parser.parse_args()
    root = args.root.resolve()
    output = (args.output or root / 'test-package').resolve()
    require(output != root and not (root / 'FractalRoseSelector').resolve().is_relative_to(output),
            'Output must not contain the project/source folder')
    if args.prepare_only:
        prepare(root, output, args.sync)
    else:
        build(root, output, args.repak.resolve() if args.repak else None, args.sync)


if __name__ == '__main__':
    main()
