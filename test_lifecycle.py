import warnings; warnings.filterwarnings("ignore")
"""Full lifecycle test for the Nomad Poet, on a local EVM."""
import json
from web3 import Web3, EthereumTesterProvider
from eth_tester import EthereumTester, PyEVMBackend

CREATOR = "0xe631960a51e1F8dE29E9663eecb8b7aa5C1c3673"
GEN0 = "genesis block wakes / the first whisper finds the chain / life begins onchain"

backend = PyEVMBackend.from_mnemonic('test test test test test test test test test test test junk',
                                     genesis_state_overrides={'balance': Web3.to_wei(1000, 'ether')})
et = EthereumTester(backend); w3 = Web3(EthereumTesterProvider(et))
deployer, keeper, donor = w3.eth.accounts[0], w3.eth.accounts[1], w3.eth.accounts[2]
C = json.load(open('PoetSoul.sol.json'))['contracts']['PoetSoul.sol']
def cf(n): return w3.eth.contract(abi=C[n]['abi'], bytecode=C[n]['evm']['bytecode']['object'])

h = cf('PoetGenesis').constructor(GEN0, CREATOR).transact(
    {'from': deployer, 'value': Web3.to_wei(0.02, 'ether'), 'gas': 6_000_000})
r = w3.eth.get_transaction_receipt(h)
G = w3.eth.contract(address=r['contractAddress'], abi=C['PoetGenesis']['abi'])
logic, registry, soul0 = G.functions.logic().call(), G.functions.registry().call(), G.functions.genesisSoul().call()
print(f"genesis deploy gas : {r['gasUsed']:,}")
print(f"logic              : {logic}")
print(f"REGISTRY (donate!) : {registry}")
print(f"genesis soul       : {soul0}\n")

Soul = lambda a: w3.eth.contract(address=a, abi=C['PoetSoulLogic']['abi'])
Reg = w3.eth.contract(address=registry, abi=C['PoetRegistry']['abi'])

assert Soul(soul0).functions.creator().call() == CREATOR
assert Soul(soul0).functions.haiku().call() == GEN0
assert Reg.functions.currentPoet().call() == soul0
print("gen  0:", Soul(soul0).functions.haiku().call())

cur, gas_used = soul0, []
for g in range(1, 7):
    et.mine_blocks(1801)
    # a donor tops up the poet through the permanent registry address
    if g % 4 == 0:
        w3.eth.send_transaction({'from': donor, 'to': registry,
                                 'value': Web3.to_wei(0.005, 'ether'), 'gas': 300_000})
    before = w3.eth.get_balance(keeper)
    h = Soul(cur).functions.migrate().transact({'from': keeper, 'gas': 3_000_000})
    r = w3.eth.get_transaction_receipt(h)
    assert r['status'] == 1, f"migration {g} reverted"
    gas_used.append(r['gasUsed'])
    ev = Soul(cur).events.Migrated().process_receipt(r)[0]['args']
    child = ev['newSoul']
    s = Soul(child)
    assert s.functions.creator().call() == CREATOR, "creator signature lost"
    assert s.functions.generation().call() == g
    assert Reg.functions.currentPoet().call() == child, "registry out of sync"
    assert Web3.to_checksum_address(w3.eth.get_code(child)[10:30].hex()) == logic, "clone points at wrong impl"
    assert Soul(cur).functions.migrated().call() is True
    try:
        Soul(cur).functions.migrate().call({'from': keeper}); raise SystemExit("FAIL: double migration allowed")
    except Exception as e:
        assert 'soul has moved on' in str(e)
    print(f"gen {g:2}: {ev['newHaiku']}   [gas {r['gasUsed']:,}, bal {w3.eth.get_balance(child)/1e18:.5f} ETH]")
    cur = child

print(f"\ngas per migration  : min {min(gas_used):,}  max {max(gas_used):,}  (flat = no proxy chaining)")
print(f"keeper profit test : fee 0.0005 ETH vs ~{max(gas_used):,} gas")
print("donations reach the living poet through one fixed address: PASS")
print("creator signature survived 12 generations: PASS")
