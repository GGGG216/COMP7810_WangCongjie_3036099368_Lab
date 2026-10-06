"""Serve a localhost-only MetaMask deployment page. Never reads wallet keys.

Build with Forge first, then run python scripts/metamask-deploy.py and open the
printed URL in the browser containing MetaMask. Approve four Sepolia requests.
Only public hashes are accepted; receipts and transaction inputs are independently
validated through a Sepolia RPC before writing evidence/sepolia.json.
"""
import argparse
import json
import re
import secrets
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROGRESS = ROOT / 'tmp/metamask-progress.json'
EVIDENCE = ROOT / 'evidence/sepolia.json'
NAMES = ('MockUSDC', 'SimpleStablecoin', 'Vault')
STEPS = (*NAMES, 'GrantRole')
CHAIN = '0xaa36a7'
ROLE = '9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6'
TOKEN = secrets.token_urlsafe(32)


def rpc(method, params=()):
    # Public endpoint only: no credential or wallet key is exposed to the page.
    request = urllib.request.Request(
        'https://ethereum-sepolia-rpc.publicnode.com',
        data=json.dumps(dict(jsonrpc='2.0', id=1, method=method, params=list(params))).encode(),
        headers={'Content-Type': 'application/json', 'User-Agent': 'StablecoinLab/1.0'})
    try:
        result = json.load(urllib.request.urlopen(request, timeout=25))
    except Exception:
        raise ValueError('Public Sepolia RPC unavailable. Saved hashes are preserved.') from None
    if 'error' in result or 'result' not in result:
        raise ValueError(f'Sepolia RPC could not complete {method}.')
    return result['result']


def artifacts():
    return {n: json.loads((ROOT / f'out/{n}.sol/{n}.json').read_text())['bytecode']['object'] for n in NAMES}


def progress():
    return json.loads(PROGRESS.read_text()) if PROGRESS.exists() else {}


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


def word(address):
    if not isinstance(address, str) or not re.fullmatch('0x[0-9a-fA-F]{40}', address):
        raise ValueError('Invalid public address.')
    return address[2:].lower().rjust(64, '0')


def record(data):
    if set(data) != {'step', 'hash'} or data['step'] not in STEPS or not re.fullmatch('0x[0-9a-fA-F]{64}', data['hash']):
        raise ValueError('Expected one public step and transaction hash.')
    saved = progress()
    if data['step'] in saved and saved[data['step']].lower() != data['hash'].lower():
        raise ValueError('A different hash already exists for this step; inspect it before proceeding.')
    saved[data['step']] = data['hash']
    atomic_json(PROGRESS, saved)
    return saved


def transaction_details(data):
    """Read canonical details rather than MetaMask's pending transaction cache."""
    if set(data) != {'hash'} or not isinstance(data['hash'], str) or data['hash'] not in progress().values():
        raise ValueError('Expected a saved public deployment hash.')
    if rpc('eth_chainId') != CHAIN:
        raise ValueError('RPC is not Ethereum Sepolia.')
    tx = rpc('eth_getTransactionByHash', [data['hash']])
    receipt = rpc('eth_getTransactionReceipt', [data['hash']])
    if not tx or not receipt:
        return {'pending': True}
    if tx.get('hash', '').lower() != data['hash'].lower() or receipt.get('transactionHash', '').lower() != data['hash'].lower():
        raise ValueError('RPC transaction hash mismatch.')
    return dict(pending=False, transaction={key: tx.get(key) for key in ('from', 'chainId', 'value', 'input', 'to')},
                receipt={key: receipt.get(key) for key in ('status', 'contractAddress')})


def validate():
    if rpc('eth_chainId') != CHAIN:
        raise ValueError('RPC is not Ethereum Sepolia.')
    saved = progress()
    if set(saved) != set(STEPS) or len(set(saved.values())) != 4:
        raise ValueError('Four distinct transaction hashes are required.')
    codes, contracts, transactions = artifacts(), {}, []
    deployer = None
    for step in STEPS:
        tx = rpc('eth_getTransactionByHash', [saved[step]])
        receipt = rpc('eth_getTransactionReceipt', [saved[step]])
        if not tx or not receipt or receipt.get('status') != '0x1':
            raise ValueError(f'{step} has not confirmed successfully. Do not redeploy blindly.')
        if tx.get('chainId') != CHAIN or int(tx.get('value', '0x0'), 16) != 0:
            raise ValueError(f'{step} has an unexpected chain or ETH transfer.')
        if tx['hash'].lower() != saved[step].lower() or receipt['transactionHash'].lower() != saved[step].lower():
            raise ValueError('Receipt/hash mismatch.')
        if deployer is None:
            deployer = tx['from']
            word(deployer)
        if tx['from'].lower() != deployer.lower():
            raise ValueError('Deployment transactions use different accounts.')
        if step in NAMES:
            args = '' if step == 'MockUSDC' else word(deployer) if step == 'SimpleStablecoin' else word(contracts['MockUSDC']['address']) + word(contracts['SimpleStablecoin']['address'])
            if tx.get('to') is not None or tx['input'].lower() != (codes[step] + args).lower():
                raise ValueError(f'{step} creation input differs from the compiled lab.')
            address = receipt.get('contractAddress')
            word(address)
            if rpc('eth_getCode', [address, 'latest']) in ('0x', '0x0', None):
                raise ValueError(f'No deployed code for {step}.')
            contracts[step] = dict(address=address, transactionHash=saved[step], deployment='confirmed', verification='pending', explorerUrl=f'https://sepolia.etherscan.io/address/{address}#code')
        else:
            expected = '0x2f2ff15d' + ROLE + word(contracts['Vault']['address'])
            if tx.get('to', '').lower() != contracts['SimpleStablecoin']['address'].lower() or tx['input'].lower() != expected:
                raise ValueError('Unexpected grantRole transaction.')
            result = rpc('eth_call', [dict(to=contracts['SimpleStablecoin']['address'], data='0x91d14854' + ROLE + word(contracts['Vault']['address'])), 'latest'])
            if int(result, 16) != 1:
                raise ValueError('Vault does not currently have MINTER_ROLE.')
        transactions.append(dict(hash=saved[step], contract=step if step in NAMES else 'SimpleStablecoin', status='confirmed'))
    evidence = dict(chainId=11155111, recordedAtUtc=datetime.now(timezone.utc).isoformat(), deployer=deployer, deployment='complete', vaultMinterRole='confirmed', contracts=contracts, transactions=transactions)
    if EVIDENCE.exists():
        prior = json.loads(EVIDENCE.read_text(encoding='utf-8-sig'))
        for name in NAMES:
            if prior['contracts'][name]['address'].lower() != contracts[name]['address'].lower():
                raise ValueError('Existing evidence belongs to another deployment; preserved.')
            contracts[name]['verification'] = prior['contracts'][name]['verification']
    atomic_json(EVIDENCE, evidence)
    return evidence


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, code, body, mime='application/json'):
        payload = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(payload)

    def trusted_host(self):
        return self.headers.get('Host') == f'127.0.0.1:{self.server.server_port}'

    def do_GET(self):
        if not self.trusted_host():
            return self.reply(403, {'error': 'Unexpected host.'})
        if self.path == '/':
            html = Path(__file__).with_suffix('.html').read_text(encoding='utf-8').replace('__SESSION_TOKEN__', TOKEN)
            return self.reply(200, html, 'text/html; charset=utf-8')
        if self.path == '/manifest':
            return self.reply(200, dict(bytecode=artifacts(), progress=progress(), role=ROLE))
        return self.reply(404, {'error': 'Not found.'})

    def do_POST(self):
        if not self.trusted_host() or self.headers.get('Origin') != f'http://127.0.0.1:{self.server.server_port}' or self.headers.get('X-Lab-Session') != TOKEN:
            return self.reply(403, {'error': 'Invalid local session.'})
        try:
            size = int(self.headers.get('Content-Length', 0))
            if not 0 < size <= 2048:
                raise ValueError('Invalid request size.')
            data = json.loads(self.rfile.read(size))
            if self.path == '/record':
                return self.reply(200, record(data))
            if self.path == '/transaction':
                return self.reply(200, transaction_details(data))
            if self.path == '/validate':
                return self.reply(200, validate())
            return self.reply(404, {'error': 'Not found.'})
        except ValueError as error:
            return self.reply(400, {'error': str(error)})
        except Exception:
            return self.reply(500, {'error': 'Validation failed; public progress is preserved.'})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=18547)
    options = parser.parse_args()
    artifacts()  # Fail before serving if the lab has not been compiled.
    server = HTTPServer(('127.0.0.1', options.port), Handler)
    print(f'Open in Edge: http://127.0.0.1:{options.port}/', flush=True)
    server.serve_forever()
