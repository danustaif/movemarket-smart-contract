#!/usr/bin/env node
// Bandingkan selector fungsi, error, dan topic0 event hasil `forge build` dengan sot/abi.json
// (bagian computed). Butuh repo source/ di sebelah repo ini.
//   node script/check-abi.mjs
//
// - ILiveMarket harus identik dengan SOT.
// - LiveMarket harus memuat semua item SOT dengan selector sama. Item tambahan hanya boleh dari
//   OpenZeppelin (Ownable, Pausable, ReentrancyGuard, SafeERC20) yang terdaftar di OZ_EXTRA.
import { execFileSync } from "node:child_process";
import fs from "node:fs";

const sot = JSON.parse(fs.readFileSync(new URL("../../source/sot/abi.json", import.meta.url), "utf8")).computed;

const OZ_EXTRA = {
  functions: ["owner()", "paused()", "renounceOwnership()", "transferOwnership(address)"],
  events: ["OwnershipTransferred(address,address)", "Paused(address)", "Unpaused(address)"],
  errors: [
    "OwnableInvalidOwner(address)",
    "OwnableUnauthorizedAccount(address)",
    "EnforcedPause()",
    "ExpectedPause()",
    "ReentrancyGuardReentrantCall()",
    "SafeERC20FailedOperation(address)",
  ],
};

const inspect = (contract, what) =>
  JSON.parse(execFileSync("forge", ["inspect", contract, what, "--json"], { encoding: "utf8" }));
// forge mengembalikan { "sig": "selector" } tanpa 0x untuk fungsi/error, dengan 0x untuk event.
const norm = (obj) => Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, v.startsWith("0x") ? v : `0x${v}`]));

const fails = [];
for (const [contract, extra] of [["ILiveMarket", null], ["LiveMarket", OZ_EXTRA]]) {
  for (const [kind, what] of [["functions", "methodIdentifiers"], ["events", "events"], ["errors", "errors"]]) {
    const got = norm(inspect(contract, what));
    const want = sot[kind];
    for (const k of Object.keys(want))
      if (got[k] !== want[k]) fails.push(`${contract} ${kind} ${k}: compile=${got[k]} sot=${want[k]}`);
    for (const k of Object.keys(got))
      if (!(k in want) && !extra?.[kind].includes(k)) fails.push(`${contract} ${kind} ${k}: tidak ada di SOT maupun allowlist`);
  }
}
if (fails.length) {
  for (const f of fails) console.log(`GAGAL  ${f}`);
  process.exit(1);
}
const n = Object.values(sot).reduce((n, o) => n + Object.keys(o).length, 0);
console.log(`ILiveMarket dan LiveMarket cocok dengan sot/abi.json (${n} item; tambahan LiveMarket hanya dari allowlist OpenZeppelin)`);
