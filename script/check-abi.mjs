#!/usr/bin/env node
// Bandingkan selector fungsi, error, dan topic0 event ILiveMarket hasil `forge build`
// dengan sot/abi.json (bagian computed). Butuh repo source/ di sebelah repo ini.
//   node script/check-abi.mjs
import { execFileSync } from "node:child_process";
import fs from "node:fs";

const sot = JSON.parse(fs.readFileSync(new URL("../../source/sot/abi.json", import.meta.url), "utf8")).computed;
const inspect = (what) => JSON.parse(execFileSync("forge", ["inspect", "ILiveMarket", what, "--json"], { encoding: "utf8" }));

// forge mengembalikan { "sig": "selector" } tanpa 0x untuk fungsi/error, dengan 0x untuk event.
const norm = (obj) => Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, v.startsWith("0x") ? v : `0x${v}`]));
const fails = [];
for (const [kind, what] of [["functions", "methodIdentifiers"], ["events", "events"], ["errors", "errors"]]) {
  const got = norm(inspect(what));
  const want = sot[kind];
  for (const k of new Set([...Object.keys(got), ...Object.keys(want)]))
    if (got[k] !== want[k]) fails.push(`${kind} ${k}: compile=${got[k]} sot=${want[k]}`);
}
if (fails.length) {
  for (const f of fails) console.log(`GAGAL  ${f}`);
  process.exit(1);
}
console.log(`ILiveMarket cocok dengan sot/abi.json (${Object.values(sot).reduce((n, o) => n + Object.keys(o).length, 0)} item)`);
