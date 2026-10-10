# Runbook deploy Monad Testnet

Urutan dari nol sampai kontrak ter-deploy, tersinkron ke SOT, terverifikasi, dan gas limit terukur. Jalankan semua perintah dari `smart-contract/` kecuali disebut lain. Repo `source/` dan `backend/` harus ada di sebelah repo ini, dan `bun install` sudah dijalankan di `../source/shared` (script `.mjs` memakai viem dari sana).

Perintah yang ditandai **MENGIRIM TRANSAKSI** membelanjakan MON dan tidak bisa dibatalkan. Sisanya hanya membaca chain atau file.

Nilai jaringan dari `../source/sot/constants.json`: chain `10143`, RPC `https://testnet-rpc.monad.xyz`, explorer `https://testnet.monadscan.com`.

## a. Wallet

Kunci deployer hanya lewat keystore `cast`, tidak pernah di file repo. Buat satu keystore per peran (password diminta tersembunyi, file di `~/.foundry/keystores/<nama>`):

```bash
cast wallet new ~/.foundry/keystores deployer   # owner LiveMarket dan MockUSDC
cast wallet new ~/.foundry/keystores resolver   # role resolver + minter tUSDC
cast wallet new ~/.foundry/keystores faucet     # wallet faucet terpisah (D19)
# kunci yang sudah ada: cast wallet import <nama> --interactive

cast wallet address --account deployer          # tampilkan alamat (minta password)
```

Sudah punya private key? Impor sebagai keystore, jangan taruh di `.env` atau chat (key diminta tersembunyi, lalu password):

```bash
cast wallet import deployer --interactive
cast wallet import resolver --interactive
cast wallet import faucet   --interactive
cast wallet list            # cek nama keystore
```

`.env` di repo ini (salin dari `.env.example`) hanya berisi alamat publik: `RESOLVER_ADDRESS`, opsional `FORWARDER_ADDRESS`, dan `MONAD_TESTNET_RPC`.

Pengguna uji untuk `measure-gas.mjs` default-nya `deployer`. Kalau ingin akun terpisah, buat keystore `user` juga.

Wallet CLI CRE terpisah: CLI `cre` membaca `CRE_ETH_PRIVATE_KEY` dari `backend/cre/.env` (isi sendiri, jangan dibagikan ke agen). Resolver service membaca `RESOLVER_PRIVATE_KEY` dan `FAUCET_PRIVATE_KEY` dari `backend/resolver/.env`. Untuk mengisinya dari keystore, jalankan sendiri di terminal: `cast wallet decrypt-keystore <nama>` (mencetak private key, jangan di sesi agen atau rekaman layar).

## b. Dana MON

Aturan Monad (SOT 13a): akun di bawah 10 MON hanya bisa mengirim 1 transaksi per 3 blok, transfer yang membuat saldo turun di bawah `min(saldo awal, 10 MON)` revert, dan akun yang baru didanai baru bisa mengirim setelah dananya berumur 3 blok.

| Wallet | Minimum | Untuk |
|---|---|---|
| deployer | 2,5 MON | Deploy sekitar 1,65 MON (simulasi 10 Okt: sekitar 8,1 juta gas, 3 transaksi, 102 gwei) + `measure-gas.mjs` sebagai owner dan user uji (batas atas sekitar 0,17 MON) + `setForwarder` nanti |
| resolver | di atas 20 MON | `lockMarkets`, `createMarkets`, `requestResolution`, `mint`. Di bawah 20 MON alert, di bawah 10 MON lock bisa tertahan (D19). `measure-gas.mjs` memakai batas atas sekitar 0,22 MON |
| faucet | minimal 10,5 MON | 10 MON reserve + 0,5 MON per kiriman (`faucet.faucetWalletMinWei`) |
| CLI CRE | di atas 10 MON | `cre workflow simulate --broadcast` membayar report (`cre.gasLimit` 1.000.000 per report) |

Total awal sekitar 45 MON. Target SOT sebelum penjurian 14 Oktober: minimal 100 MON, ideal 160 MON (SOT 13).

Sumber:

```bash
# faucet agen Monad (dari monskills; batas per alamat belum diketahui)
curl -s -X POST https://agents.devnads.com/v1/faucet \
  -H "Content-Type: application/json" \
  -d '{"chainId":10143,"address":"0x..."}'
```

Lalu faucet resmi Monad Testnet dan tim Monad di Discord untuk jumlah besar. Cek saldo dan tunggu 3 blok (sekitar 1,2 detik) setelah dana masuk sebelum wallet itu mengirim transaksi:

```bash
cast balance <alamat> --ether --rpc-url https://testnet-rpc.monad.xyz
```

## c. Deploy

```bash
forge build && forge test && node script/check-abi.mjs
export RESOLVER_ADDRESS=$(cast wallet address --account resolver)

# 1. simulasi tanpa transaksi
forge script script/Deploy.s.sol --rpc-url https://testnet-rpc.monad.xyz --account deployer

# 2. MENGIRIM TRANSAKSI (3 transaksi: MockUSDC, LiveMarket, setMinter)
forge script script/Deploy.s.sol --rpc-url https://testnet-rpc.monad.xyz --account deployer --broadcast --slow
```

`FORWARDER_ADDRESS` dibiarkan kosong: default MockKeystoneForwarder SOT (`addresses.creMockKeystoneForwarder` di `../source/sot/constants.json`). `--slow` menunggu receipt tiap transaksi, cocok dengan batas 1 transaksi per 3 blok untuk akun di bawah 10 MON.

Hasil: `deployments/monad-testnet.json` (commit file ini) dan `broadcast/Deploy.s.sol/10143/run-latest.json` (dipakai `verify.mjs`, tidak di-commit). Deploy ulang menimpa keduanya.

Hati-hati: `anvil --chain-id 10143` dengan `--broadcast` menulis ke path yang sama. `sync-sot.mjs` dan `verify.mjs` menolak file sisa anvil karena kode kontraknya tidak ada di Monad Testnet.

## d. Sinkronkan SOT dan config CRE

```bash
node script/sync-sot.mjs --dry-run   # cetak perubahan
node script/sync-sot.mjs
```

Script memvalidasi file deployment (chain 10143, alamat checksum, forwarder sama dengan forwarder SOT) dan state on-chain (`token`, `forwarder`, `resolver`, `owner`, minter tUSDC), lalu menulis `addresses.liveMarket`, `mockUsdc`, `resolver`, `deployBlock` di `../source/sot/constants.json` dan `liveMarketAddress` di config tiap target `cre.targets` SOT (`../backend/cre/<cre.workflowName>/config.*.json`), kemudian menjalankan `node sot/check.mjs`. Di akhir ia mencetak nilai env untuk langkah g.

Commit di masing-masing repo: `source` dengan awalan `sot:`, `backend` untuk config CRE. Lalu `cd ../backend/cre/resolver-workflow && bun test` (test config menagih alamat yang sama dengan SOT).

## e. Verifikasi

```bash
node script/verify.mjs --dry-run     # pra-cek creation code + tampilkan request
node script/verify.mjs               # kirim ke API verifikasi (bukan transaksi chain)
node script/verify.mjs --sourcify    # paksa jalur cadangan
```

Pra-cek: input transaksi deploy on-chain harus sama dengan bytecode `out/` + constructor args. Kalau gagal, `forge build` dari commit yang di-deploy dulu.

Jalur utama `POST` ke `verification.apiUrl` SOT (MonadVision, Socialscan, Monadscan sekaligus), bentuk body dari monskills v0.7.2 `skills/scaffold/SKILL.md`. Respons API dicetak apa adanya. Kalau API gagal, script otomatis menjalankan `forge verify-contract ... --verifier sourcify --verifier-url <verification.sourcifyUrl SOT>`. Cek tab Contract di explorer. Indexer Envio butuh kontrak terverifikasi.

## f. Ukur gas limit (D22)

Jalankan sekali tepat setelah deploy, sebelum resolver service hidup (resolver service memakai wallet yang sama, nonce bisa bentrok). Deployment baru memberi angka worst case paling akurat.

```bash
# MENGIRIM TRANSAKSI (12 transaksi). Cetak perkiraan biaya lalu minta konfirmasi y.
node script/measure-gas.mjs --owner deployer --resolver resolver --write
```

- Batas atas biaya: sekitar 3,8 juta gas, sekitar 0,39 MON pada 102 gwei (resolver 0,22, deployer 0,17). Pemakaian nyata lebih kecil karena tiap transaksi memakai `estimate + 10%`.
- `cast` meminta password keystore setiap transaksi. Kalau semua keystore memakai password yang sama: `ETH_PASSWORD=<file berisi password>`.
- Tanpa `--write` hanya mencetak tabel, transaksi tetap dikirim. `--user <keystore>` untuk pengguna uji terpisah.
- Skenario: 8 pasar uji di partai fixture `lichess:game:e9SJcXpJ` (sudah selesai), 5 bet 1 tUSDC, lock, `requestResolution` 8 pasar, `adminVoid` + `refund` satu pasar. `setForwarder` hanya diestimasi.
- `claim` dan `claimMany` tidak bisa diukur di sini: pasar RESOLVED hanya lewat `onReport` dari forwarder CRE. Setelah report CRE pertama (langkah h) untuk tx `requestResolution` yang dicetak script, jalankan perintah `cast estimate` yang dicetak, tambah 10%, dan ubah `gas.limits.claim` hanya kalau hasilnya di atas nilai SOT. Saldo tUSDC user saat itu tidak nol, jadi tambahkan sekitar 17.000 gas untuk kasus saldo nol (SSTORE 0 ke bukan nol). `claimMany` di SOT satu limit datar; script hanya mencetak angka per pasar dari anvil.

Setelah `--write`: perbarui status "Gas nyata semua fungsi" di `docs/SOT.md` bagian 16, commit `sot:` di `source/`, lalu `cd ../backend/resolver && bun test`.

## g. Env resolver dan frontend

Isi sendiri, jangan commit `.env`. Nilai alamat dicetak `sync-sot.mjs`.

`backend/resolver/.env` (daftar lengkap `backend/resolver/.env.example`, arti di `source/docs/ARCHITECTURE.md` bagian 8):

| Variabel | Isi |
|---|---|
| `MONAD_TESTNET_RPC`, `MONAD_TESTNET_WS` | RPC HTTP dan WebSocket |
| `LIVE_MARKET_ADDRESS`, `MOCK_USDC_ADDRESS`, `DEPLOY_BLOCK` | Dari `sync-sot.mjs` |
| `RESOLVER_PRIVATE_KEY` | Secret, keystore `resolver` |
| `FAUCET_PRIVATE_KEY` | Secret, keystore `faucet` |
| `ADMIN_TOKEN` | Secret, acak |
| `CRE_MODE`, `CRE_PROJECT_DIR`, `CRE_TARGET` | `simulate`, `../cre`, `staging-settings` |
| `CORS_ORIGIN`, `TRUST_PROXY`, `PORT` | Sesuai hosting |

`fe/.env`: `VITE_CHAIN_ID`, `VITE_RPC_URL`, `VITE_RESOLVER_URL`, `VITE_ENVIO_URL`, `VITE_LIVE_MARKET_ADDRESS`, `VITE_MOCK_USDC_ADDRESS`, `VITE_RP_ID`.

## h. Langkah berikutnya

Simulasi CRE dengan tx `requestResolution` nyata (misalnya yang dibuat `measure-gas.mjs`), setelah bloknya finalized. Dari `backend/cre/` (detail di `backend/cre/README.md`):

```bash
# 0. tanpa receiver (wajib pertama)
cre workflow simulate resolver-workflow --target local-simulation \
  --non-interactive --trigger-index 0 --evm-tx-hash <hash> --evm-event-index 0
# 1. dry run target onchain, tanpa transaksi
cre workflow simulate resolver-workflow --target staging-settings \
  --non-interactive --trigger-index 0 --evm-tx-hash <hash> --evm-event-index 0
# 2. MENGIRIM TRANSAKSI: report lewat MockKeystoneForwarder, dibayar wallet CRE_ETH_PRIVATE_KEY
cre workflow simulate resolver-workflow --target staging-settings \
  --non-interactive --trigger-index 0 --evm-tx-hash <hash> --evm-event-index 0 --broadcast
```

Indexer Envio (setelah kontrak terverifikasi), perintah dari SOT `indexer.init`:

```bash
pnpx envio@3.0.0-alpha.21 init contract-import explorer -b monad-testnet -c <LIVE_MARKET_ADDRESS> -n LiveMarket -l typescript -d ./ -o ./ --all-events --single-contract --api-token ""
```

Start block indexer = `addresses.deployBlock`.

## i. GatedForwarder untuk `CRE_MODE=mock` (SOT D24)

MockKeystoneForwarder Chainlink `0xB9F79d...` permissionless: siapa pun bisa memanggil `report()` dan menetapkan hasil pasar. Selama resolver memakai `CRE_MODE=mock`, pasang `GatedForwarder` (`src/GatedForwarder.sol`) yang hanya menerima `report()` dari wallet resolver. ABI `report()` dan event `ReportProcessed` sama dengan mock Chainlink, jadi resolver cukup membaca alamat baru dari SOT.

Biaya (102 gwei, Monad menagih gas limit): deploy sekitar 0,066 MON (limit forge sekitar 643.000 gas, terpakai 494.509 di anvil), `setForwarder` sekitar 0,004 MON (`gas.limits.setForwarder` 38.375). Deployer dan owner di atas 0,1 MON sudah cukup.

```bash
forge build && forge test
export OPERATOR_ADDRESS=$(cast wallet address --account resolver)   # wallet RESOLVER_PRIVATE_KEY resolver service

# 1. simulasi tanpa transaksi
forge script script/DeployGatedForwarder.s.sol --rpc-url https://testnet-rpc.monad.xyz --account deployer

# 2. MENGIRIM TRANSAKSI (1 transaksi: deploy GatedForwarder)
forge script script/DeployGatedForwarder.s.sol --rpc-url https://testnet-rpc.monad.xyz --account deployer --broadcast --slow

# 3. sinkron ke SOT: validasi kode dan operator() on-chain, tulis addresses.creGatedForwarder, jalankan sot/check.mjs
node script/sync-sot.mjs --gated --dry-run
node script/sync-sot.mjs --gated

# 4. verifikasi explorer (bukan transaksi chain), constructor arg operator
node script/verify.mjs --gated --dry-run
node script/verify.mjs --gated

# 5. MENGIRIM TRANSAKSI: owner LiveMarket memindahkan forwarder ke GatedForwarder
cast send <LIVE_MARKET> "setForwarder(address)" <GATED_FORWARDER> \
  --gas-limit 38375 --rpc-url https://testnet-rpc.monad.xyz --account deployer
cast call <LIVE_MARKET> "forwarder()(address)" --rpc-url https://testnet-rpc.monad.xyz   # cek
```

`<LIVE_MARKET>` = `addresses.liveMarket`, `<GATED_FORWARDER>` = `addresses.creGatedForwarder` di `../source/sot/constants.json` (`sync-sot.mjs --gated` mencetak perintah langkah 5 dengan alamat terisi). `--account` = keystore owner `LiveMarket` (deployer).

Hasil: `deployments/gated-forwarder.monad-testnet.json` (commit file ini, awalan `contracts:`) dan perubahan SOT (commit `sot:` di `source/`). Lalu deploy ulang resolver: tanpa env baru, forwarder diambil dari SOT. Saat start ia membaca `LiveMarket.forwarder()`; kalau beda dengan GatedForwarder ia mencatat `cre_forwarder_mismatch` dan tidak mengirim report. Sama seperti `Deploy.s.sol`, `anvil --chain-id 10143` dengan `--broadcast` menulis path yang sama; `sync-sot.mjs --gated` menolak file sisa anvil karena kodenya tidak ada di Monad Testnet.

Kembali ke forwarder Chainlink (MENGIRIM TRANSAKSI, gas sama):

```bash
# demo cre workflow simulate --broadcast: MockKeystoneForwarder (kembali permissionless selama terpasang)
cast send <LIVE_MARKET> "setForwarder(address)" 0xB9F79d863261869B234c481D1f9A7af84AeAd192 \
  --gas-limit 38375 --rpc-url https://testnet-rpc.monad.xyz --account deployer
# DON (setelah Early Access, bersamaan dengan CRE_MODE=don): KeystoneForwarder, buka ulang Forwarder Directory dulu
cast send <LIVE_MARKET> "setForwarder(address)" 0xF8344CFd5c43616a4366C34E3EEE75af79a74482 \
  --gas-limit 38375 --rpc-url https://testnet-rpc.monad.xyz --account deployer
```

Selama forwarder bukan GatedForwarder, resolver `CRE_MODE=mock` berhenti mengirim report (`cre_forwarder_mismatch`). Setelah demo `simulate --broadcast`, kembalikan dengan perintah langkah 5.
