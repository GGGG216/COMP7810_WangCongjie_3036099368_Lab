"""Build the Assignment Two ZIP from an explicit file allowlist, never git history."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'output' / 'submission'
NAME = 'COMP7810_WangCongjie_3036099368_Lab'
ROOT_FILES = (
    'README.md', 'SUBMISSION.md', 'STUDENT-QUESTIONS.md', 'EXERCISES.md',
    'Makefile', 'foundry.toml', 'foundry.lock', 'remappings.txt',
    '.env.example', '.gitignore', '.gitattributes', '.dockerignore',
)
DIRECTORIES = ('src', 'test', 'script', 'scripts', '.devcontainer',
               'lib/forge-std/src', 'lib/openzeppelin-contracts/contracts')
EVIDENCE = ('deployment.txt', 'doctor.txt', 'ex1-ex3.json', 'ex1-ex3.txt',
            'ex3.png', 'forge-test.txt', 'index.html', 'tests.png')


def selected_files():
    paths = {ROOT / name for name in ROOT_FILES}
    for directory in DIRECTORIES:
        paths.update(p for p in (ROOT / directory).rglob('*')
                     if p.is_file() and '__pycache__' not in p.parts)
    for directory in ('lib/forge-std', 'lib/openzeppelin-contracts'):
        paths.update((ROOT / directory).glob('LICENSE*'))
        paths.add(ROOT / directory / 'package.json')
        paths.add(ROOT / directory / 'README.md')
    paths.update(ROOT / 'evidence' / name for name in EVIDENCE)
    if (ROOT / 'evidence/sepolia.json').exists():
        paths.add(ROOT / 'evidence/sepolia.json')
    for path in paths:
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(ROOT):
            raise ValueError(f'Missing or unsafe package input: {path.relative_to(ROOT)}')
        relative = path.relative_to(ROOT)
        if any(part in ('.git', '.tools', 'broadcast', 'cache', 'out') or
               (part.startswith('.env') and relative.as_posix() != '.env.example') for part in relative.parts):
            raise ValueError(f'Forbidden runtime/credential file in package: {relative}')
    return sorted(paths)


def configured_secrets():
    """Compare without emitting secret values. This function never executes .env."""
    path = ROOT / '.env'
    if not path.exists():
        return []
    values = []
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        match = re.match(r'\s*(?:export\s+)?(?:PRIVATE_KEY|ETHERSCAN_API_KEY)\s*=\s*(.*?)\s*$', line)
        if match:
            value = match[1].split(' #', 1)[0].strip().strip('\"\'')
            if len(value) >= 12 and set(value.removeprefix('0x')) != {'0'}:
                values.append(value.encode())
    return values


def check_secret_material(files):
    assignment = re.compile(
        r'''(?im)(?:[\w-]*(?:private[_ -]?key|anvil_key|attack_key)|--private-key)["']?\s*(?:[:=]\s*|\s+)["']?(?:0x)?[0-9a-f]{64}(?![0-9a-f])'''
    )
    seed = re.compile(r'''(?im)(?:mnemonic|seed[_ -]?phrase)\s*[:=]\s*["'](?:[a-z]+\s+){11,23}[a-z]+["']''')
    secrets = configured_secrets()
    for path in files:
        data = path.read_bytes()
        relative = path.relative_to(ROOT).as_posix()
        if any(secret in data for secret in secrets):
            raise ValueError(f'Configured credential found in {relative}; value suppressed.')
        if path.suffix.lower() in ('.png', '.jpg', '.jpeg'):
            continue  # Screenshots are inspected visually as well.
        text = data.decode('utf-8-sig')
        if assignment.search(text) or seed.search(text) or re.search(r'-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----', text):
            raise ValueError(f'Possible private key/seed literal in {relative}; value suppressed.')


def moodle_text(final):
    prefix = 'COMP7810A Assignment Two - Stablecoin Lab\nWang Congjie, 3036099368\n\n'
    path = ROOT / 'evidence/sepolia.json'
    data = json.loads(path.read_text(encoding='utf-8-sig')) if path.exists() else {}
    names = ('MockUSDC', 'SimpleStablecoin', 'Vault')
    entries = data.get('contracts', {})
    ready = data.get('chainId') == 11155111 and data.get('deployment') == 'complete'
    ready = ready and data.get('vaultMinterRole') == 'confirmed'
    addresses = []
    for name in names:
        entry = entries.get(name, {})
        address = entry.get('address', '')
        ready = ready and bool(re.fullmatch(r'0x[0-9a-fA-F]{40}', address))
        ready = ready and address.lower() != '0x' + '0' * 40
        ready = ready and entry.get('deployment') == 'confirmed' and entry.get('verification') == 'verified'
        addresses.append(address)
    ready = ready and len(set(a.lower() for a in addresses)) == 3
    if final and not ready:
        raise ValueError('Final ZIP refused: three confirmed, verified Sepolia contracts are required.')
    if final and 'Tier 2 status: PENDING' in (ROOT / 'SUBMISSION.md').read_text(encoding='utf-8'):
        raise ValueError('Update the pending status in SUBMISSION.md and README.md after verification.')
    if not ready:
        return prefix + 'DRAFT - DO NOT SUBMIT THIS TEXT AS COMPLETED TIER 2.\nSepolia deployment/verification is pending.\n\n' + '\n\n'.join(
            f'{name}\nAddress: PENDING\nEtherscan verified source: PENDING' for name in names
        ) + '\n', False
    return prefix + 'Network: Ethereum Sepolia (chain ID 11155111)\n\n' + '\n\n'.join(
        f'{name}\nAddress: {address}\nVerified source: https://sepolia.etherscan.io/address/{address}#code'
        for name, address in zip(names, addresses)
    ) + '\n', True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--final', action='store_true', help='Require completed Tier 2 evidence.')
    args = parser.parse_args()
    files = selected_files()
    check_secret_material(files)
    text, tier2_ready = moodle_text(args.final)
    OUT.mkdir(parents=True, exist_ok=True)
    suffix = '' if args.final else '_DRAFT'
    archive = OUT / f'{NAME}{suffix}.zip'
    hashes = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    with ZipFile(archive, 'w', compression=ZIP_DEFLATED, compresslevel=9) as package:
        for path in files:
            package.write(path, path.relative_to(ROOT).as_posix())
    with ZipFile(archive) as package:
        if package.testzip() is not None or set(package.namelist()) != set(hashes):
            raise ValueError('ZIP integrity or contents verification failed.')
        for name, digest in hashes.items():
            if hashlib.sha256(package.read(name)).hexdigest() != digest:
                raise ValueError(f'Archived bytes differ for {name}.')
    (OUT / f'MOODLE_TEXT{suffix}.txt').write_text(text, encoding='utf-8')
    report = {
        'archive': archive.name, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
        'file_count': len(files), 'tier2_ready': tier2_ready, 'final': args.final,
        'private_key_scan': 'passed (literal patterns and configured key values)',
        'dependencies': 'Complete runtime sources and licenses; dependency self-tests omitted.',
        'excluded': ['.env', '.git', '.tools', 'broadcast', 'cache', 'out', 'tmp', 'output', 'dependency self-tests'],
        'file_sha256': hashes,
    }
    (OUT / 'PACKAGE_REPORT.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(f'{archive}\n{len(files)} files; {archive.stat().st_size:,} bytes; Tier 2 ready: {tier2_ready}')


if __name__ == '__main__':
    main()
