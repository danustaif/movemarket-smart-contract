# movemarket-smart-contract

Project overview, architecture, and CRE evidence: [movemarket-source README](https://github.com/danustaif/movemarket-source#readme).

Kontrak `LiveMarket` (pasar parimutuel + consumer report Chainlink CRE) dan `MockUSDC` (tUSDC) untuk Monad Testnet.

Spesifikasi: `../source/docs/CONTRACTS.md`. Nilai kanonik: `../source/sot/`. Clone repo `movemarket-source` di sebelah repo ini.

## Status

Kontrak, test, dan script deploy selesai. Ter-deploy di Monad Testnet dan terverifikasi (perfect match) di MonadVision dan Monadscan:

| Kontrak | Alamat |
|---|---|
| LiveMarket | [`0xA40F0D8f2e70bfd8F52B4d08089bD083cBdDB9a9`](https://testnet.monadscan.com/address/0xA40F0D8f2e70bfd8F52B4d08089bD083cBdDB9a9) |
| MockUSDC | [`0x3670C61f0179dAEF70574C5f6cdC20b7d9986561`](https://testnet.monadscan.com/address/0x3670C61f0179dAEF70574C5f6cdC20b7d9986561) |

Alamat kanonik dan blok deploy ada di `source/sot/constants.json`; file deploy di `deployments/monad-testnet.json`.

| File | Isi |
|---|---|
| `src/LiveMarket.sol` | `ILiveMarket` + OpenZeppelin `ReentrancyGuard`, `Pausable`, `Ownable`. Implementasi `IReceiver` sendiri (tanpa `ReceiverTemplate`) |
| `src/MockUSDC.sol` | tUSDC 6 desimal, `setMinter` (owner), `mint` (minter) |
| `src/interfaces/ILiveMarket.sol` | Struct, event, error, fungsi, invarian di NatSpec |
| `src/interfaces/LiveMarketTypes.sol` | Enum dan konstanta (`MAX_*`, `VOID_*`, `SKIP_*`) |
| `src/interfaces/IMockUSDC.sol` | Fungsi tambahan tUSDC di atas ERC20 |
| `src/interfaces/IReceiver.sol`, `IERC165.sol` | Disalin dari dokumentasi CRE, jangan diubah |
| `script/Deploy.s.sol` | Deploy MockUSDC + LiveMarket, set resolver sebagai minter, tulis `deployments/monad-testnet.json` |
| `script/check-abi.mjs` | Selector dan topic0 `ILiveMarket` dan `LiveMarket` harus sama dengan `sot/abi.json` |
| `script/sync-sot.mjs` | Pasca-deploy: validasi `deployments/monad-testnet.json`, tulis alamat ke `sot/constants.json` dan config CRE (padanan `sync:contracts`) |
| `script/verify.mjs` | Verifikasi MockUSDC dan LiveMarket (API `agents.devnads.com`, cadangan Sourcify) |
| `script/measure-gas.mjs` | Ukur `gas.limits` SOT dengan `eth_estimateGas` + 10% lewat skenario transaksi nyata |
| `test/` | Test per fungsi sesuai `CONTRACTS.md` bagian 7, invariant, dan test script deploy. `test/mocks/MockForwarder.sol` meneruskan `onReport` |

Dependensi (submodule di `lib/`): OpenZeppelin Contracts v5.7.0, forge-std v1.17.0. Setelah clone: `git submodule update --init --recursive`.

## Perintah

```bash
forge build
forge test                       # termasuk invariant (runs 128, depth 128)
forge test --match-test gas_report -vv   # gas onReport batch 8 dan 40 (storage dingin)
node script/check-abi.mjs        # wajib lulus sebelum commit
```

Urutan mengubah ABI: `source/sot/abi.json` dulu, `node sot/check.mjs` di `source/`, baru Solidity.

## Deploy

Env:

| Nama | Wajib | Isi |
|---|---|---|
| `RESOLVER_ADDRESS` | ya | Wallet resolver: role resolver `LiveMarket` dan minter tUSDC |
| `FORWARDER_ADDRESS` | tidak | Default `addresses.creMockKeystoneForwarder` di `sot/constants.json`. Pindah ke `KeystoneForwarder` nanti lewat `setForwarder` |

Kunci deployer hanya lewat CLI (`--account <keystore>` atau `--private-key`), tidak pernah di file.

```bash
# simulasi lokal, tanpa transaksi
RESOLVER_ADDRESS=0x... forge script script/Deploy.s.sol

# Monad Testnet
RESOLVER_ADDRESS=0x... forge script script/Deploy.s.sol \
  --rpc-url $MONAD_TESTNET_RPC --account <keystore> --broadcast --slow
```

Script menolak chain selain `network.chainId` SOT (10143) dan anvil (31337). `deployments/monad-testnet.json` hanya ditulis saat `--broadcast` di 10143; `deployBlock` di file itu adalah blok sebelum deploy (batas bawah, aman sebagai start block indexer).

Urutan lengkap (wallet, dana MON, deploy, sinkron SOT, verifikasi, ukur gas, env, simulasi CRE, indexer) ada di [DEPLOY.md](DEPLOY.md). Ringkas:

```bash
node script/sync-sot.mjs                 # alamat -> ../source/sot/constants.json + config CRE, lalu sot/check.mjs
node script/verify.mjs                   # verifikasi explorer (--dry-run untuk melihat request)
node script/measure-gas.mjs --owner deployer --resolver resolver --write   # MENGIRIM TRANSAKSI
```

Ketiga script Node ESM tanpa `package.json` sendiri: viem diambil dari `../source/shared/node_modules` (`bun install` di sana). Semua punya `--rpc` untuk uji di `anvil --chain-id 10143`.
