// Helper bersama script pasca-deploy (sync-sot, verify, measure-gas). Node ESM murni.
// viem diambil dari source/shared (versi yang sama dengan resolver, CRE, dan fe), jadi repo ini tidak
// punya package.json sendiri. Prasyarat: `bun install` di ../source/shared.
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SOURCE = path.resolve(ROOT, "../source");
const BACKEND = path.resolve(ROOT, "../backend");

export const paths = {
  root: ROOT,
  source: SOURCE,
  constants: path.join(SOURCE, "sot/constants.json"),
  deployment: path.join(ROOT, "deployments/monad-testnet.json"),
  creConfigs: ["staging", "production", "local-simulation"].map((t) =>
    path.join(BACKEND, `cre/resolver-workflow/config.${t}.json`)),
};

const req = createRequire(path.join(SOURCE, "shared/package.json"));
export const viem = req("viem");
export const { privateKeyToAccount } = req("viem/accounts");
export const { monadTestnet } = req("viem/chains");

export const readJson = (p) => JSON.parse(fs.readFileSync(p, "utf8"));

/** deployments/monad-testnet.json dengan pesan jelas kalau belum ada deploy. */
export function readDeployment(p = paths.deployment) {
  if (!fs.existsSync(p)) fail(`${path.relative(process.cwd(), p)} belum ada. Deploy dulu (DEPLOY.md langkah c).`);
  return readJson(p);
}
/** Format sama dengan file SOT dan config CRE (indentasi 2, newline akhir); urutan kunci dipertahankan. */
export const writeJson = (p, v) => fs.writeFileSync(p, JSON.stringify(v, null, 2) + "\n");

export const artifact = (name) => readJson(path.join(ROOT, `out/${name}.sol/${name}.json`));

export function fail(msg) {
  console.error(`\nGAGAL: ${msg}`);
  process.exit(1);
}

/** Alamat wajib checksum EIP-55 persis dan bukan nol. */
export function checksummed(label, a) {
  let c;
  try { c = viem.getAddress(a); } catch { fail(`${label} bukan alamat: ${a}`); }
  if (c !== a) fail(`${label} tidak dalam format checksum: ${a} (seharusnya ${c})`);
  if (c === viem.zeroAddress) fail(`${label} alamat nol`);
  return c;
}

export function publicClient(rpc) {
  return viem.createPublicClient({ chain: monadTestnet, transport: viem.http(rpc) });
}

/** Tolak RPC yang bukan chain SOT (anvil harus dijalankan dengan --chain-id 10143). */
export async function assertChain(pub, sot) {
  const id = await pub.getChainId();
  if (id !== sot.network.chainId) fail(`RPC chain ${id}, harus ${sot.network.chainId} (anvil: --chain-id ${sot.network.chainId})`);
}
