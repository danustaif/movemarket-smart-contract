#!/usr/bin/env node
// Verifikasi MockUSDC dan LiveMarket di explorer Monad Testnet (SOT verification, CONTRACTS.md bagian 9).
//
//   node script/verify.mjs [--dry-run] [--sourcify] [--rpc <url>] [--deployment <file>]
//
// Jalur utama: POST SOT verification.apiUrl (MonadVision, Socialscan, Monadscan sekaligus).
// Bentuk body dari monskills v0.7.2 skills/scaffold/SKILL.md bagian "Verification (All Explorers)":
// chainId, contractAddress, contractName (path:Name), compilerVersion (v...), standardJsonInput (dari
// `forge verify-contract --show-standard-json-input`), foundryMetadata (`.metadata` artefak out/), dan
// constructorArgs (ABI-encoded tanpa 0x, hanya kalau ada). Format respons API belum pernah diamati:
// dicetak apa adanya. Kalau API gagal (atau --sourcify), jalur cadangan forge + verification.sourcifyUrl.
//
// Pra-cek: creation code on-chain (input tx deploy dari broadcast/Deploy.s.sol/<chain>/run-latest.json)
// harus sama dengan bytecode out/ + constructorArgs. Kalau beda, build lokal bukan yang di-deploy dan
// verifikasi pasti gagal.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { artifact, assertChain, fail, paths, publicClient, readJson, viem, readDeployment } from "./lib.mjs";

const { values: o } = parseArgs({
  options: {
    "dry-run": { type: "boolean" }, sourcify: { type: "boolean" },
    rpc: { type: "string" }, deployment: { type: "string" },
  },
});
const sot = readJson(paths.constants);
const { apiUrl: API, sourcifyUrl: SOURCIFY } = sot.verification;
const d = readDeployment(o.deployment);
const pub = publicClient(o.rpc ?? sot.network.rpcPublic);
await assertChain(pub, sot);

const contracts = [
  { name: "MockUSDC", address: d.mockUsdc, args: [] },
  { name: "LiveMarket", address: d.liveMarket, args: [d.mockUsdc, d.forwarder, d.resolver] },
];

const broadcastFile = path.join(paths.root, `broadcast/Deploy.s.sol/${d.chainId}/run-latest.json`);
const deployTxs = fs.existsSync(broadcastFile) ? readJson(broadcastFile).transactions : null;
if (!deployTxs) console.warn(`PERINGATAN: ${path.relative(paths.root, broadcastFile)} tidak ada, pra-cek creation code dilewati.`);

let failed = 0;
for (const c of contracts) {
  console.log(`\n== ${c.name} ${c.address}`);
  const art = artifact(c.name);
  const ctor = art.abi.find((x) => x.type === "constructor");
  const encoded = ctor ? viem.encodeAbiParameters(ctor.inputs, c.args) : "0x";
  const constructorArgs = encoded.slice(2);

  if (deployTxs) await checkCreationCode(c, art.bytecode.object + constructorArgs);

  const contractName = `src/${c.name}.sol:${c.name}`;
  const fallback = ["verify-contract", c.address, contractName, "--chain", String(sot.network.chainId),
    "--verifier", "sourcify", "--verifier-url", SOURCIFY,
    ...(constructorArgs ? ["--constructor-args", encoded] : [])];

  if (o.sourcify) {
    if (o["dry-run"]) console.log(`forge ${fallback.join(" ")}`);
    else if (!runFallback(fallback)) failed++;
    continue;
  }

  const body = {
    chainId: sot.network.chainId,
    contractAddress: c.address,
    contractName,
    compilerVersion: `v${art.metadata.compiler.version}`,
    standardJsonInput: standardJsonInput(c.address, contractName),
    foundryMetadata: art.metadata,
    ...(constructorArgs ? { constructorArgs } : {}),
  };

  if (o["dry-run"]) {
    const size = (v) => `<${JSON.stringify(v).length} byte>`;
    console.log(`POST ${API}`);
    console.log(JSON.stringify({ ...body, standardJsonInput: size(body.standardJsonInput), foundryMetadata: size(body.foundryMetadata) }, null, 2));
    console.log(`cadangan: forge ${fallback.join(" ")}`);
    continue;
  }

  let res, text;
  try {
    res = await fetch(API, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    text = await res.text();
  } catch (e) {
    text = String(e);
  }
  console.log(`API ${res?.status ?? "error"}: ${text}`);
  if (!res?.ok) {
    console.log("API gagal, pakai jalur cadangan Sourcify.");
    if (!runFallback(fallback)) failed++;
  }
}

if (failed) fail(`${failed} kontrak gagal diverifikasi`);
console.log(`\nSelesai. Cek ${sot.network.explorer}/address/${d.liveMarket} (tab Contract).`);

async function checkCreationCode(c, expected) {
  const t = deployTxs.find((x) => x.transactionType === "CREATE" && x.contractAddress?.toLowerCase() === c.address.toLowerCase());
  if (!t?.hash) fail(`tx deploy ${c.name} ${c.address} tidak ada di ${broadcastFile}`);
  const tx = await pub.getTransaction({ hash: t.hash });
  if (tx.input.toLowerCase() !== expected.toLowerCase()) {
    fail(`creation code on-chain ${c.name} (tx ${t.hash}) beda dengan out/${c.name}.sol + constructorArgs. ` +
      "Build ulang dari commit yang di-deploy (forge build) sebelum verifikasi.");
  }
  console.log(`creation code on-chain cocok dengan out/ + constructorArgs (tx ${t.hash})`);
}

function standardJsonInput(address, contractName) {
  const r = spawnSync("forge", ["verify-contract", address, contractName, "--chain", String(sot.network.chainId), "--show-standard-json-input"],
    { cwd: paths.root, encoding: "utf8", maxBuffer: 64 << 20 });
  if (r.status !== 0) fail(`forge --show-standard-json-input gagal:\n${r.stderr}`);
  return JSON.parse(r.stdout);
}

function runFallback(args) {
  console.log(`forge ${args.join(" ")}`);
  return spawnSync("forge", args, { cwd: paths.root, stdio: "inherit" }).status === 0;
}
