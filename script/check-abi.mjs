#!/usr/bin/env node
// Bandingkan selector fungsi, error, dan topic0 event hasil `forge build` dengan sot/abi.json
// (bagian computed). Butuh repo source/ di sebelah repo ini.
//   node script/check-abi.mjs
//
// - ILiveMarket harus identik dengan SOT.
// - LiveMarket harus memuat semua item SOT dengan selector sama. Item tambahan hanya boleh dari
//   OpenZeppelin (Ownable, Pausable, ReentrancyGuard, SafeERC20) yang terdaftar di OZ_EXTRA.
// - MockUSDC harus memuat semua fungsi dan error di sot mockUsdc (selector dihitung dari ABI
//   human-readable). Tambahan hanya boleh dari ERC20 dan Ownable OpenZeppelin (OZ_ERC20_EXTRA).
import { execFileSync } from "node:child_process";
import { paths, readJson, viem } from "./lib.mjs";

const abiJson = readJson(`${paths.source}/sot/abi.json`);
const sot = abiJson.computed;

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

const OWNABLE = {
  functions: ["owner()", "renounceOwnership()", "transferOwnership(address)"],
  events: ["OwnershipTransferred(address,address)"],
  errors: ["OwnableInvalidOwner(address)", "OwnableUnauthorizedAccount(address)"],
};
const OZ_ERC20_EXTRA = {
  functions: [
    ...OWNABLE.functions,
    "name()", "symbol()", "totalSupply()", "balanceOf(address)", "transfer(address,uint256)",
    "allowance(address,address)", "approve(address,uint256)", "transferFrom(address,address,uint256)",
  ],
  events: [...OWNABLE.events, "Transfer(address,address,uint256)", "Approval(address,address,uint256)"],
  errors: [
    ...OWNABLE.errors,
    "ERC20InsufficientAllowance(address,uint256,uint256)", "ERC20InsufficientBalance(address,uint256,uint256)",
    "ERC20InvalidApprover(address)", "ERC20InvalidReceiver(address)", "ERC20InvalidSender(address)",
    "ERC20InvalidSpender(address)",
  ],
};

/** Selector item sot mockUsdc, format sama dengan bagian computed. */
function mockUsdcSot() {
  const want = { functions: {}, events: {}, errors: {} };
  const m = abiJson.mockUsdc;
  for (const item of viem.parseAbi([...m.functions, ...(m.errors ?? [])])) {
    if (item.type === "function") want.functions[viem.toFunctionSignature(item)] = viem.toFunctionSelector(item);
    if (item.type === "error") {
      const sig = `${item.name}(${item.inputs.map((i) => i.type).join(",")})`;
      want.errors[sig] = viem.toFunctionSelector(sig);
    }
  }
  return want;
}

const inspect = (contract, what) =>
  JSON.parse(execFileSync("forge", ["inspect", contract, what, "--json"], { encoding: "utf8" }));
// forge mengembalikan { "sig": "selector" } tanpa 0x untuk fungsi/error, dengan 0x untuk event.
const norm = (obj) => Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, v.startsWith("0x") ? v : `0x${v}`]));

const fails = [];
const targets = [["ILiveMarket", sot, null], ["LiveMarket", sot, OZ_EXTRA], ["MockUSDC", mockUsdcSot(), OZ_ERC20_EXTRA]];
for (const [contract, sotItems, extra] of targets) {
  for (const [kind, what] of [["functions", "methodIdentifiers"], ["events", "events"], ["errors", "errors"]]) {
    const got = norm(inspect(contract, what));
    const want = sotItems[kind];
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
const count = (o) => Object.values(o).reduce((n, x) => n + Object.keys(x).length, 0);
console.log(
  `ILiveMarket, LiveMarket (${count(sot)} item), dan MockUSDC (${count(targets[2][1])} item) cocok dengan sot/abi.json; ` +
    "tambahan hanya dari allowlist OpenZeppelin",
);
