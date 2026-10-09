# movemarket-smart-contract

Kontrak `LiveMarket` (pasar parimutuel + consumer report Chainlink CRE) dan `MockUSDC` (tUSDC) untuk Monad Testnet.

Spesifikasi: `../source/docs/CONTRACTS.md`. Nilai kanonik: `../source/sot/`. Clone repo `movemarket-source` di sebelah repo ini.

## Status

Tahap antarmuka. Yang sudah ada:

| File | Isi |
|---|---|
| `src/interfaces/ILiveMarket.sol` | Struct, event, error, dan fungsi `LiveMarket`, plus invarian di NatSpec |
| `src/interfaces/LiveMarketTypes.sol` | Enum dan konstanta (`MAX_*`, `VOID_*`, `SKIP_*`) |
| `src/interfaces/IMockUSDC.sol` | Fungsi tambahan tUSDC di atas ERC20 |
| `src/interfaces/IReceiver.sol`, `IERC165.sol` | Disalin dari dokumentasi CRE, jangan diubah |
| `script/check-abi.mjs` | Selector dan topic0 hasil compile harus sama dengan `sot/abi.json` |

Berikutnya: `LiveMarket.sol is ILiveMarket` dan `MockUSDC.sol is ERC20, Ownable, IMockUSDC` (perlu `forge install OpenZeppelin/openzeppelin-contracts`), test di `docs/CONTRACTS.md` bagian 7, `script/Deploy.s.sol`.

## Perintah

```bash
forge build
node script/check-abi.mjs     # wajib lulus sebelum commit
```

Urutan mengubah ABI: `source/sot/abi.json` dulu, `node sot/check.mjs` di `source/`, baru Solidity.
