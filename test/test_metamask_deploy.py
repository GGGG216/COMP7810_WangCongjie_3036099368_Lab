"""Regression checks for public deployment evidence validation (no wallet keys)."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('metamask_deploy', Path(__file__).resolve().parents[1] / 'scripts/metamask-deploy.py')
APP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APP)


class DeploymentEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(patch.stopall)
        patch.object(APP, 'PROGRESS', Path(self.temp.name) / 'progress.json').start()
        patch.object(APP, 'EVIDENCE', Path(self.temp.name) / 'evidence.json').start()
        self.codes = {n: '0x60' + str(i) + '0' for i, n in enumerate(APP.NAMES, 1)}
        patch.object(APP, 'artifacts', return_value=self.codes).start()
        self.admin = '0x' + '11' * 20
        self.addresses = {n: '0x' + f'{i:02x}' * 20 for i, n in enumerate(APP.NAMES, 2)}
        self.hashes = {n: '0x' + f'{i:064x}' for i, n in enumerate(APP.STEPS, 1)}
        self.transactions, self.receipts = {}, {}
        for n in APP.STEPS:
            data, to = '', None
            if n == 'MockUSDC':
                data = self.codes[n]
            elif n == 'SimpleStablecoin':
                data = self.codes[n] + APP.word(self.admin)
            elif n == 'Vault':
                data = self.codes[n] + APP.word(self.addresses['MockUSDC']) + APP.word(self.addresses['SimpleStablecoin'])
            else:
                to = self.addresses['SimpleStablecoin']
                data = '0x2f2ff15d' + APP.ROLE + APP.word(self.addresses['Vault'])
            tx_hash = self.hashes[n]
            self.transactions[tx_hash] = dict(hash=tx_hash, chainId=APP.CHAIN, value='0x0', to=to, input=data, **{'from': self.admin})
            self.receipts[tx_hash] = dict(status='0x1', transactionHash=tx_hash, contractAddress=self.addresses.get(n))
            APP.record(dict(step=n, hash=tx_hash))
        self.chain = APP.CHAIN
        self.role = '0x1'
        patch.object(APP, 'rpc', side_effect=self.rpc).start()

    def rpc(self, method, params=()):
        if method == 'eth_chainId': return self.chain
        if method == 'eth_getTransactionByHash': return self.transactions[params[0]]
        if method == 'eth_getTransactionReceipt': return self.receipts[params[0]]
        if method == 'eth_getCode': return '0x6000'
        if method == 'eth_call': return self.role
        raise AssertionError(method)

    def assert_refused(self):
        with self.assertRaises(ValueError): APP.validate()
        self.assertFalse(APP.EVIDENCE.exists())

    def test_valid_receipts_create_public_evidence(self):
        result = APP.validate()
        self.assertEqual(result['deployment'], 'complete')
        self.assertEqual(result['contracts']['Vault']['verification'], 'pending')
        self.assertEqual(result['deployer'], self.admin)

    def test_wrong_network_refused(self):
        self.chain = '0x1'
        self.assert_refused()

    def test_failed_receipt_refused(self):
        self.receipts[self.hashes['Vault']]['status'] = '0x0'
        self.assert_refused()

    def test_different_creation_code_refused(self):
        self.transactions[self.hashes['MockUSDC']]['input'] += '00'
        self.assert_refused()

    def test_different_sender_refused(self):
        self.transactions[self.hashes['Vault']]['from'] = self.addresses['Vault']
        self.assert_refused()

    def test_eth_transfer_refused(self):
        self.transactions[self.hashes['MockUSDC']]['value'] = '0x1'
        self.assert_refused()

    def test_missing_role_refused(self):
        self.role = '0x0'
        self.assert_refused()

    def test_existing_hash_cannot_be_replaced(self):
        with self.assertRaises(ValueError):
            APP.record(dict(step='Vault', hash=self.hashes['MockUSDC']))
        self.assertEqual(APP.progress()['Vault'], self.hashes['Vault'])

    def test_canonical_transaction_comes_from_rpc(self):
        details = APP.transaction_details({'hash': self.hashes['MockUSDC']})
        self.assertFalse(details['pending'])
        self.assertEqual(details['transaction']['input'], self.codes['MockUSDC'])
        self.assertEqual(details['transaction']['chainId'], APP.CHAIN)
        self.assertEqual(details['receipt']['contractAddress'], self.addresses['MockUSDC'])

    def test_transaction_lookup_rejects_unknown_hash(self):
        with self.assertRaises(ValueError):
            APP.transaction_details({'hash': '0x' + 'ff' * 32})

    def test_transaction_lookup_rejects_wrong_network(self):
        self.chain = '0x1'
        with self.assertRaises(ValueError):
            APP.transaction_details({'hash': self.hashes['MockUSDC']})


if __name__ == '__main__':
    unittest.main()
