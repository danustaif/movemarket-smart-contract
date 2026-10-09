#!/usr/bin/env node
// Ukur gas limit SOT gas.limits (D22): eth_estimateGas terhadap kontrak yang sudah di-deploy + gas.bufferPct.
//
//   node script/measure-gas.mjs --owner <akun> --resolver <akun> [--user <akun>] [--forwarder <akun>]
//                               [--rpc <url>] [--write] [--yes] [--deployment <file>]
//
// <akun> salah satu:
//   <nama>       keystore cast di ~/.foundry/keystores (transaksi lewat `cast send --account <nama>`;
//                cast meminta password, atau set ETH_PASSWORD=<file berisi password>)
//   <path/file>  keystore cast di path itu (`cast send --keystore <path>`)
//   env:<VAR>    private key dari env VAR saat runtime, tidak pernah dicetak (dipakai untuk anvil)
// --user default = --owner. --forwarder hanya bisa di anvil (forwarder kontrak = akun yang kita pegang).
//
// Estimasi butuh state nyata, jadi script MENGIRIM TRANSAKSI berurutan, masing-masing dengan
// gas = ceil(estimate * (1 + bufferPct/100)):
//   mint (resolver -> user, kalau saldo kurang), approve, createMarkets (K pasar), 5 bet, lockMarkets,
//   requestResolution (tx-nya bisa dipakai simulasi CRE), adminVoid + refund pasar terakhir.
//   setForwarder, dan mint/approve/createMarkets versi worst case, hanya diestimasi (tidak dikirim).
//   Batch: base + perMarket dari estimasi n=1 dan n=K, K = resolver.REQUEST_MAX_BATCH.
// Angka worst case (slot nol) paling akurat di deployment baru: jalankan sekali tepat setelah deploy.
// claim/claimMany (batch: claimManyBase + claimManyPerMarket dari n=1 dan n=2) butuh pasar RESOLVED, yang hanya bisa lewat onReport dari forwarder. Di Monad forwarder
// adalah kontrak Chainlink, jadi keduanya diukur setelah report CRE pertama (perintah dicetak di akhir).
// Pasar uji memakai partai fixture sot/fixtures/lichess/game-export.finished-mate.json (sudah selesai).
// Tanpa --write hanya mencetak tabel; dengan --write mengisi ../source/sot/constants.json gas.limits lalu
// menjalankan `node sot/check.mjs`.
import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import path from "node:path";
import readline from "node:readline/promises";
import { setTimeout as sleep } from "node:timers/promises";
import { parseArgs } from "node:util";
import {
  artifact, assertChain, fail, monadTestnet, paths, privateKeyToAccount, publicClient, readJson, runSotCheck, viem, writeJson,
  readDeployment } from "./lib.mjs";

const { values: o } = parseArgs({
  options: {
    rpc: { type: "string" }, owner: { type: "string" }, resolver: { type: "string" }, user: { type: "string" },
    forwarder: { type: "string" }, write: { type: "boolean" }, yes: { type: "boolean" }, deployment: { type: "string" },
  },
});
if (!o.owner || !o.resolver) fail("wajib --owner dan --resolver (lihat komentar di atas script)");

const sot = readJson(paths.constants);
const d = readDeployment(o.deployment);
const rpc = o.rpc ?? sot.network.rpcPublic;
const pub = publicClient(rpc);
await assertChain(pub, sot);

const lm = { address: d.liveMarket, abi: artifact("LiveMarket").abi };
const usdc = { address: d.mockUsdc, abi: artifact("MockUSDC").abi };
const read = (c, functionName, args = []) => pub.readContract({ ...c, functionName, args });

const owner = await signer(o.owner, "owner");
const resolver = await signer(o.resolver, "resolver");
const user = o.user ? await signer(o.user, "user") : { ...owner, label: "user" };
const fwd = o.forwarder ? await signer(o.forwarder, "forwarder") : null;

// ------------------------------------------------------------------ pra-cek peran
if ((await read(lm, "owner")) !== owner.address) fail(`--owner ${owner.address} bukan owner LiveMarket`);
if ((await read(lm, "resolver")) !== resolver.address) fail(`--resolver ${resolver.address} bukan resolver LiveMarket`);
if (!(await read(usdc, "minters", [resolver.address]))) fail(`resolver ${resolver.address} bukan minter tUSDC`);
const currentForwarder = await read(lm, "forwarder");
if (fwd && currentForwarder !== fwd.address) fail(`forwarder kontrak ${currentForwarder}, bukan --forwarder ${fwd.address}`);

const K = sot.resolver.REQUEST_MAX_BATCH;
const fixture = readJson(path.join(paths.source, "sot/fixtures/lichess/game-export.finished-mate.json"));
const gameRefOf = (gameId) => sot.gameRef.formats.find((f) => f.kind === "game").pattern.replace("{gameId}", gameId);
const GAME_REF = gameRefOf(fixture.id);
// Rentang ply seperti planner di replay: mulai setelah REPLAY_START_PLY, satu pasar per SPAWN_EVERY_PLIES.
const { REPLAY_START_PLY } = sot.resolver;
const { SPAWN_EVERY_PLIES, WINDOW_PLIES } = sot.planner;
if (REPLAY_START_PLY + SPAWN_EVERY_PLIES * K > fixture.moves.split(" ").length) fail("fixture terlalu pendek untuk K pasar");
const enumIndex = (name, value) => sot.enums[name].indexOf(value);

// ------------------------------------------------------------------ perkiraan biaya
// Batas atas kasar gas limit per langkah: hasil anvil ditambah biaya akses dingin Monad (+6.000 per slot).
const PLAN = [
  [resolver, "mint", 120_000], [user, "approve", 90_000], [resolver, `createMarkets x${K}`, 1_500_000],
  [user, "bet x5", 5 * 250_000], [resolver, `lockMarkets x${K}`, 250_000], [resolver, `requestResolution x${K}`, 300_000],
  [owner, "adminVoid", 120_000], [user, "refund", 150_000],
  ...(fwd ? [[fwd, "onReport x3", 400_000], [user, "claim + claimMany", 400_000]] : []),
];
const gasPrice = await pub.getGasPrice();
const mon = (wei) => `${viem.formatEther(wei)} MON`;
console.log(`RPC ${rpc}, gas price ${viem.formatGwei(gasPrice)} gwei (Monad menagih gas limit x harga).`);
console.log(`LiveMarket ${lm.address}, partai uji ${GAME_REF}, K = ${K}.\n\nPerkiraan biaya maksimum:`);
const perAccount = new Map();
for (const [who, step, gas] of PLAN) {
  console.log(`  ${who.label.padEnd(9)} ${step.padEnd(22)} <= ${gas} gas`);
  perAccount.set(who.address, (perAccount.get(who.address) ?? 0n) + BigInt(gas) * gasPrice);
}
let total = 0n;
const floor = viem.parseEther(String(sot.gas.budget.walletFloorMon)); // reserve balance SOT 13a
for (const [address, cost] of perAccount) {
  const balance = await pub.getBalance({ address });
  total += cost;
  const warn = balance < cost ? "  SALDO KURANG" : balance - cost < floor ? `  (di bawah ${sot.gas.budget.walletFloorMon} MON: 1 tx per 3 blok)` : "";
  console.log(`  ${address}: ${mon(cost)}, saldo ${mon(balance)}${warn}`);
}
console.log(`  total <= ${mon(total)}\n`);
if (!o.yes) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const answer = await rl.question("Kirim transaksi di atas? [y/N] ");
  rl.close();
  if (answer.trim().toLowerCase() !== "y") fail("dibatalkan");
}

// ------------------------------------------------------------------ skenario
const bufferPct = sot.gas.bufferPct;
const buffered = (g) => (g * BigInt(100 + bufferPct) + 99n) / 100n; // ceil(g * (1 + bufferPct/100))
const call = (c, functionName, args) => ({ to: c.address, data: viem.encodeFunctionData({ abi: c.abi, functionName, args }) });
const estimate = (who, c, fn, args) => pub.estimateGas({ account: who.address, ...call(c, fn, args) });
let spent = 0n;

async function send(who, c, fn, args) {
  const est = await estimate(who, c, fn, args);
  const gas = buffered(est);
  const r = await who.send({ ...call(c, fn, args), gas });
  if (r.status !== "success") fail(`${fn} revert (tx ${r.transactionHash})`);
  spent += gas * r.effectiveGasPrice;
  console.log(`  ${who.label.padEnd(9)} ${fn.padEnd(18)} estimate ${String(est).padStart(8)}  gas ${String(gas).padStart(8)}  ${r.transactionHash}`);
  await sleep(sot.frontend.minTxGapMs); // akun < 10 MON hanya 1 tx per 3 blok (SOT 13a)
  return { est, hash: r.transactionHash };
}

const single = {}; // nama SOT -> estimate terbesar
const note = (name, est) => { single[name] = single[name] > est ? single[name] : est; };
const batches = {}; // fn -> [estimate n=1, estimate n=k, k]
const balanceOf = (a) => read(usdc, "balanceOf", [a]);

// Worst case: slot penyimpanan masih nol (SSTORE 0 -> bukan nol). Yang bisa, diestimasi terhadap alamat
// atau gameRef acak yang belum pernah dipakai (hanya estimasi, tidak dikirim), supaya hasil sama walau
// script dijalankan ulang. Saldo tUSDC user dibuat habis oleh bet terakhir agar refund/claim juga worst case.
const fresh = () => viem.getAddress(viem.toHex(randomBytes(20)));
const freshRef = gameRefOf(randomBytes(6).toString("base64url")); // panjang sama dengan GAME_REF

console.log("Skenario (MENGIRIM TRANSAKSI):");
const minBet = await read(lm, "minBet");
const BETS = 5n;
note("mint", await estimate(resolver, usdc, "mint", [fresh(), BETS * minBet]));
const held = await balanceOf(user.address);
if (held < BETS * minBet) await send(resolver, usdc, "mint", [user.address, BETS * minBet - held]);
note("approve", await estimate(user, usdc, "approve", [fresh(), viem.maxUint256]));
await send(user, usdc, "approve", [lm.address, viem.maxUint256]);

const first = await read(lm, "nextMarketId");
const ids = Array.from({ length: K }, (_, i) => first + BigInt(i));
const lockTime = (await pub.getBlock()).timestamp + BigInt(sot.contract.MAX_BET_WINDOW_SEC) - 60n;
const params = (n, gameRef) => Array.from({ length: n }, (_, i) => ({
  gameRef, marketType: enumIndex("MarketType", i % 2 ? "CAPTURE" : "CHECK"), side: enumIndex("Side", "ANY"),
  fromPly: REPLAY_START_PLY + 1 + SPAWN_EVERY_PLIES * i, toPly: REPLAY_START_PLY + SPAWN_EVERY_PLIES * i + WINDOW_PLIES,
  lockTime, resolveDeadline: lockTime + BigInt(sot.planner.RESOLVE_DEADLINE_SEC),
}));
batches.createMarkets = [
  await estimate(resolver, lm, "createMarkets", [params(1, freshRef)]),
  await estimate(resolver, lm, "createMarkets", [params(K, freshRef)]), K];
await send(resolver, lm, "createMarkets", [params(K, GAME_REF)]);

if ((await balanceOf(lm.address)) > 0n) {
  console.log("  PERINGATAN: saldo tUSDC LiveMarket sudah > 0, estimasi bet sekitar 17.000 gas di bawah worst case (bet pertama sejak deploy).");
}
// Bet pertama dan kedua (sisi lain) di pasar yang sama, lalu pasar lain; pasar terakhir (untuk refund)
// menerima sisa saldo supaya saldo user nol.
for (const [id, yes] of [[ids[0], true], [ids[0], false], [ids[1], true], [ids[2], true]]) {
  note("bet", (await send(user, lm, "bet", [id, yes, minBet])).est);
}
const rest = await balanceOf(user.address);
const maxStake = await read(lm, "maxStakePerUser");
note("bet", (await send(user, lm, "bet", [ids[K - 1], true, rest < maxStake ? rest : maxStake])).est);

const lock1 = await estimate(resolver, lm, "lockMarkets", [[ids[0]]]);
batches.lockMarkets = [lock1, (await send(resolver, lm, "lockMarkets", [ids])).est, K];

const req1 = await estimate(resolver, lm, "requestResolution", [GAME_REF, [ids[0]]]);
const request = await send(resolver, lm, "requestResolution", [GAME_REF, ids]);
batches.requestResolution = [req1, request.est, K];

note("adminVoid", (await send(owner, lm, "adminVoid", [[ids[K - 1]]])).est); // limit datar, diukur n=1

// setForwarder hanya diestimasi: nilai yang benar-benar akan diset (pindah mock <-> produksi).
const nextForwarder = currentForwarder === sot.addresses.creKeystoneForwarder
  ? sot.addresses.creMockKeystoneForwarder : sot.addresses.creKeystoneForwarder;
note("setForwarder", await estimate(owner, lm, "setForwarder", [nextForwarder]));
console.log(`  ${"owner".padEnd(9)} ${"setForwarder".padEnd(18)} estimate ${String(single.setForwarder).padStart(8)}  (tidak dikirim)`);

if (fwd) {
  const report = viem.encodeAbiParameters(viem.parseAbiParameters(sot.cre.reportAbi),
    [viem.keccak256(viem.toBytes(GAME_REF)), ids.slice(0, 3), Array(3).fill(sot.outcomeCode.YES)]);
  const onReport = await send(fwd, lm, "onReport", ["0x", report]);
  console.log(`  (onReport 3 pasar langsung dari forwarder: estimate ${onReport.est}; info untuk cre.gasLimit, bukan gas.limits)`);
}

// refund/claim diestimasi selagi saldo user nol, baru dikirim.
if ((await balanceOf(user.address)) > 0n) console.log("  PERINGATAN: saldo tUSDC user > 0, estimasi refund/claim di bawah worst case.");
note("refund", await estimate(user, lm, "refund", [ids[K - 1]]));
if (fwd) {
  note("claim", await estimate(user, lm, "claim", [ids[0]]));
  // Batch seperti createMarkets: base + perMarket x n dari n=1 dan n=2.
  batches.claimMany = [await estimate(user, lm, "claimMany", [[ids[1]]]), await estimate(user, lm, "claimMany", [[ids[1], ids[2]]]), 2];
}
await send(user, lm, "refund", [ids[K - 1]]);
if (fwd) {
  await send(user, lm, "claim", [ids[0]]);
  await send(user, lm, "claimMany", [[ids[1], ids[2]]]);
}

// ------------------------------------------------------------------ hasil
const limits = {};
for (const [name, est] of Object.entries(single)) limits[name] = buffered(est);
for (const [fn, [one, many, k]] of Object.entries(batches)) {
  const per = (many - one + BigInt(k - 2)) / BigInt(k - 1); // ceil((many - one) / (k - 1))
  limits[`${fn}Base`] = buffered(one - per);
  limits[`${fn}PerMarket`] = buffered(per);
}

console.log(`\nHasil (limit = estimate + ${bufferPct}%; batch: base + perMarket x n dari n=1 dan n=${K}):`);
console.log(`  ${"nama".padEnd(28)} ${"limit".padStart(9)}  SOT sekarang`);
for (const name of Object.keys(sot.gas.limits)) {
  const v = limits[name];
  const now = sot.gas.limits[name];
  const why = name === "nativeTransfer" ? "tetap"
    : name.startsWith("claim") ? "belum diukur" : "tidak diukur";
  console.log(`  ${name.padEnd(28)} ${(v === undefined ? "-" : String(v)).padStart(9)}  ${now ?? "null"}${v === undefined ? `  (${why})` : ""}`);
}
if (!fwd) {
  console.log(`
claim dan claimMany belum diukur: pasar RESOLVED hanya lewat onReport dari forwarder CRE.
Ukur setelah report CRE pertama untuk requestResolution di atas (tx ${request.hash},
pasar ${ids[0]}..${ids[K - 1]}; user stake di ${ids[0]} kedua sisi, ${ids[1]} dan ${ids[2]} YES), misalnya:
  cast estimate ${lm.address} "claim(uint256)" ${ids[0]} --from ${user.address} --rpc-url ${rpc}
  cast estimate ${lm.address} "claimMany(uint256[])" "[${ids[1]}]" --from ${user.address} --rpc-url ${rpc}
  cast estimate ${lm.address} "claimMany(uint256[])" "[${ids[1]},${ids[2]}]" --from ${user.address} --rpc-url ${rpc}
lalu tambah ${bufferPct}%: gas.limits.claim; claimManyPerMarket = n2 - n1, claimManyBase = n1 - perMarket.`);
}
console.log(`\nrequestResolution ${request.hash} (pasar ${ids[0]}..${ids[K - 1]}) bisa dipakai untuk simulasi CRE setelah bloknya finalized.`);
console.log(`Biaya terpakai: ${mon(spent)}.`);

if (o.write) {
  const j = readJson(paths.constants);
  for (const [name, v] of Object.entries(limits)) {
    if (!(name in j.gas.limits)) fail(`kunci ${name} tidak ada di gas.limits SOT`);
    j.gas.limits[name] = Number(v);
  }
  writeJson(paths.constants, j);
  console.log(`\nDitulis ke ${path.relative(paths.root, paths.constants)}.`);
  runSotCheck();
} else {
  console.log("\nTanpa --write: SOT tidak diubah.");
}

// ------------------------------------------------------------------ akun
async function signer(spec, label) {
  if (spec.startsWith("env:")) {
    const pk = process.env[spec.slice(4)];
    if (!pk) fail(`env ${spec.slice(4)} kosong (--${label})`);
    const account = privateKeyToAccount(pk.startsWith("0x") ? pk : `0x${pk}`);
    const wallet = viem.createWalletClient({ account, chain: monadTestnet, transport: viem.http(rpc) });
    return {
      label, address: account.address,
      send: async (tx) => pub.waitForTransactionReceipt({ hash: await wallet.sendTransaction(tx) }),
    };
  }
  // Keystore cast: script tidak membaca file keystore; cast yang meminta password dan menandatangani.
  const flag = spec.includes("/") ? ["--keystore", spec] : ["--account", spec];
  console.log(`cast wallet address ${flag.join(" ")} (${label})`);
  const address = viem.getAddress(cast(["wallet", "address", ...flag]).trim());
  return {
    label, address,
    send: async ({ to, data, gas }) => {
      const out = cast(["send", to, "--data", data, "--gas-limit", String(gas), "--rpc-url", rpc, "--json", ...flag]);
      return pub.getTransactionReceipt({ hash: JSON.parse(out).transactionHash });
    },
  };
}

function cast(args) {
  const r = spawnSync("cast", args, { stdio: ["inherit", "pipe", "inherit"], encoding: "utf8" });
  if (r.status !== 0) fail(`cast ${args[0]} ${args[1]} gagal`);
  return r.stdout;
}
