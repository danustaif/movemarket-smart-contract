#!/usr/bin/env node
// Padanan `sync:contracts` (CONTRACTS.md bagian 9 langkah 5): salin hasil deploy ke SOT dan config CRE.
//
//   node script/sync-sot.mjs [--dry-run] [--rpc <url>] [--deployment <file>]
//   node script/sync-sot.mjs --gated [--dry-run] [--rpc <url>] [--deployment <file>]
//
// Membaca deployments/monad-testnet.json, memvalidasi (chain SOT, alamat checksum, forwarder SOT, dan
// state on-chain di --rpc, default RPC publik SOT), lalu menulis:
//   ../source/sot/constants.json          addresses.liveMarket, mockUsdc, resolver, deployBlock
//   ../backend/cre/<cre.workflowName>/<config tiap cre.targets>  liveMarketAddress
// dan menjalankan `node sot/check.mjs` di ../source. --dry-run hanya mencetak perubahan.
// Tidak menyentuh .env mana pun; nilai env yang harus diisi user dicetak di akhir (alamat publik).
//
// --gated (SOT D24): membaca deployments/gated-forwarder.monad-testnet.json, memvalidasi (chain, checksum, kode dan
// operator() on-chain), lalu hanya menulis addresses.creGatedForwarder. LiveMarket.forwarder tidak diubah.
import path from "node:path";
import { parseArgs } from "node:util";
import {
  artifact, assertChain, checksummed, fail, paths, publicClient, readJson, runSotCheck, writeJson, readDeployment,
} from "./lib.mjs";

const { values: o } = parseArgs({
  options: { "dry-run": { type: "boolean" }, gated: { type: "boolean" }, rpc: { type: "string" }, deployment: { type: "string" } },
});
const sot = readJson(paths.constants);
if (o.gated) {
  await syncGated();
  process.exit(0);
}
const d = readDeployment(o.deployment);

// ------------------------------------------------------------------ validasi file
if (d.chainId !== sot.network.chainId) fail(`chainId ${d.chainId}, harus ${sot.network.chainId}`);
for (const k of ["liveMarket", "mockUsdc", "forwarder", "owner", "resolver"]) checksummed(k, d[k]);
const forwarders = [sot.addresses.creMockKeystoneForwarder, sot.addresses.creKeystoneForwarder];
if (!forwarders.includes(d.forwarder)) fail(`forwarder ${d.forwarder} bukan forwarder SOT (${forwarders.join(" / ")})`);
if (!Number.isSafeInteger(d.deployBlock) || d.deployBlock < 0) fail(`deployBlock tidak valid: ${d.deployBlock}`);

// ------------------------------------------------------------------ validasi on-chain
// Menangkap file sisa uji anvil (anvil --chain-id 10143 juga menulis deployments/monad-testnet.json).
const rpc = o.rpc ?? sot.network.rpcPublic;
const pub = publicClient(rpc);
await assertChain(pub, sot);
const lmAbi = artifact("LiveMarket").abi;
const read = (functionName) => pub.readContract({ address: d.liveMarket, abi: lmAbi, functionName });
for (const k of ["liveMarket", "mockUsdc"]) {
  if (!(await pub.getCode({ address: d[k] }))) fail(`tidak ada kode di ${k} ${d[k]} pada ${rpc}`);
}
const onchain = { token: d.mockUsdc, forwarder: d.forwarder, resolver: d.resolver, owner: d.owner };
for (const [fn, want] of Object.entries(onchain)) {
  const got = await read(fn);
  if (got !== want) fail(`LiveMarket.${fn}() = ${got}, file deployment ${want}`);
}
const minter = await pub.readContract({
  address: d.mockUsdc, abi: artifact("MockUSDC").abi,
  functionName: "minters", args: [d.resolver],
});
if (!minter) fail(`resolver ${d.resolver} belum minter di MockUSDC`);
console.log(`Deployment valid di ${rpc} (chain ${d.chainId}, blok deploy ${d.deployBlock}).\n`);

// ------------------------------------------------------------------ rencana perubahan
const edits = [
  [paths.constants, sot, (j) => Object.assign(j.addresses, {
    liveMarket: d.liveMarket, mockUsdc: d.mockUsdc, resolver: d.resolver, deployBlock: d.deployBlock,
  })],
  ...paths.creConfigs.map((p) => [p, readJson(p), (j) => { j.liveMarketAddress = d.liveMarket; }]),
];

applyEdits(edits);

console.log(`
Isi .env berikut sendiri (alamat publik, bukan secret):
  backend/resolver/.env
    LIVE_MARKET_ADDRESS=${d.liveMarket}
    MOCK_USDC_ADDRESS=${d.mockUsdc}
    DEPLOY_BLOCK=${d.deployBlock}
  fe/.env
    VITE_LIVE_MARKET_ADDRESS=${d.liveMarket}
    VITE_MOCK_USDC_ADDRESS=${d.mockUsdc}`);

/** Tulis (atau dengan --dry-run hanya cetak) perubahan, lalu sot/check.mjs kalau ada yang berubah. */
function applyEdits(edits) {
  let changed = 0;
  for (const [file, json, apply] of edits) {
    const before = JSON.parse(JSON.stringify(json));
    apply(json);
    const diff = diffLines(before, json);
    console.log(`${path.relative(paths.root, file)}: ${diff.length ? "" : "tidak berubah"}`);
    for (const line of diff) console.log(`  ${line}`);
    if (diff.length) {
      changed++;
      if (!o["dry-run"]) writeJson(file, json);
    }
  }
  if (o["dry-run"]) console.log(`\n--dry-run: ${changed} file akan berubah, tidak ada yang ditulis.`);
  else if (changed) runSotCheck();
}

/** --gated: addresses.creGatedForwarder dari deployments/gated-forwarder.monad-testnet.json. */
async function syncGated() {
  const g = readDeployment(o.deployment ?? paths.gatedDeployment);
  if (g.chainId !== sot.network.chainId) fail(`chainId ${g.chainId}, harus ${sot.network.chainId}`);
  for (const k of ["gatedForwarder", "operator"]) checksummed(k, g[k]);

  const rpc = o.rpc ?? sot.network.rpcPublic;
  const pub = publicClient(rpc);
  await assertChain(pub, sot);
  if (!(await pub.getCode({ address: g.gatedForwarder }))) fail(`tidak ada kode di gatedForwarder ${g.gatedForwarder} pada ${rpc}`);
  const operator = await pub.readContract({ address: g.gatedForwarder, abi: artifact("GatedForwarder").abi, functionName: "operator" });
  if (operator !== g.operator) fail(`GatedForwarder.operator() = ${operator}, file deployment ${g.operator}`);
  if (sot.addresses.resolver && operator !== sot.addresses.resolver) {
    console.warn(`PERINGATAN: operator ${operator} bukan addresses.resolver SOT ${sot.addresses.resolver}; runner mock hanya jalan kalau RESOLVER_PRIVATE_KEY = operator.`);
  }
  console.log(`GatedForwarder valid di ${rpc}: ${g.gatedForwarder}, operator ${operator}.\n`);

  applyEdits([[paths.constants, sot, (j) => { j.addresses.creGatedForwarder = g.gatedForwarder; }]]);

  const lm = sot.addresses.liveMarket;
  const current = await pub.readContract({ address: lm, abi: artifact("LiveMarket").abi, functionName: "forwarder" })
    .catch(() => "(tidak terbaca)");
  console.log(`
LiveMarket.forwarder() sekarang ${current}. Pindahkan ke GatedForwarder (DEPLOY.md bagian i, MENGIRIM TRANSAKSI):
  cast send ${lm} "setForwarder(address)" ${g.gatedForwarder} --gas-limit ${sot.gas.limits.setForwarder} --rpc-url ${rpc} --account deployer`);
}

/** Diff per kunci daun: `jalur: lama -> baru`. */
function diffLines(a, b, prefix = "") {
  const out = [];
  for (const k of new Set([...Object.keys(a ?? {}), ...Object.keys(b ?? {})])) {
    const [x, y] = [a?.[k], b?.[k]];
    if (x && y && typeof x === "object" && typeof y === "object") out.push(...diffLines(x, y, `${prefix}${k}.`));
    else if (JSON.stringify(x) !== JSON.stringify(y)) out.push(`${prefix}${k}: ${JSON.stringify(x)} -> ${JSON.stringify(y)}`);
  }
  return out;
}
