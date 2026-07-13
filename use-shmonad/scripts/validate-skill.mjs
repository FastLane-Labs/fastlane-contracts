#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { IMPLEMENTATION_SLOT, NETWORKS } from "./verify-deployment.mjs";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const skillRoot = path.resolve(scriptDir, "..");
const repositoryRoot = path.resolve(skillRoot, "..");

const requiredFiles = [
  "SKILL.md",
  "agents/openai.yaml",
  "references/deployments-and-rpc.md",
  "references/holder-operations.md",
  "references/policies.md",
  "references/validators-and-admin.md",
  "references/events-and-errors.md",
  "references/shmonad-abi.json",
  "scripts/validate-skill.mjs",
  "scripts/verify-deployment.mjs",
];

function fail(message) {
  throw new Error(message);
}

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, stable(value[key])]),
    );
  }
  return value;
}

function canonicalType(input) {
  if (!input.type.startsWith("tuple")) return input.type;
  const suffix = input.type.slice("tuple".length);
  return `(${input.components.map(canonicalType).join(",")})${suffix}`;
}

function functionSignature(item) {
  return `${item.name}(${(item.inputs ?? []).map(canonicalType).join(",")})`;
}

function markdownAnchors(body) {
  const counts = new Map();
  const anchors = new Set();
  for (const line of body.split(/\r?\n/)) {
    const match = line.match(/^#{1,6}\s+(.+?)\s*#*$/);
    if (!match) continue;
    const base = match[1]
      .toLowerCase()
      .replace(/<[^>]*>/g, "")
      .replace(/[`*_~]/g, "")
      .replace(/[^a-z0-9_\s-]/g, "")
      .trim()
      .replace(/\s+/g, "-");
    const duplicate = counts.get(base) ?? 0;
    counts.set(base, duplicate + 1);
    anchors.add(duplicate === 0 ? base : `${base}-${duplicate}`);
  }
  return anchors;
}

function walkMarkdown(directory, output = []) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) walkMarkdown(absolute, output);
    else if (entry.name.endsWith(".md")) output.push(absolute);
  }
  return output;
}

function normalizeReferenceLabel(label) {
  return label.trim().replace(/\s+/g, " ").toLowerCase();
}

function cleanLinkTarget(rawTarget) {
  const target = rawTarget.trim();
  if (target.startsWith("<")) {
    const end = target.indexOf(">");
    return end === -1 ? target : target.slice(1, end);
  }
  return target.split(/\s+(?=["'])/, 1)[0];
}

function validateLinks() {
  const markdownFiles = walkMarkdown(skillRoot);
  const anchorCache = new Map();
  const broken = [];

  function validateTarget(source, rawTarget) {
    const target = cleanLinkTarget(rawTarget);
    if (/^(https?:|mailto:)/i.test(target)) return;
    if (/^[a-z][a-z0-9+.-]*:/i.test(target)) {
      broken.push(
        `${path.relative(skillRoot, source)} -> unsupported target ${target}`,
      );
      return;
    }

    const separator = target.indexOf("#");
    const rawFile = separator === -1 ? target : target.slice(0, separator);
    const rawFragment = separator === -1 ? "" : target.slice(separator + 1);
    let destination;
    try {
      destination = rawFile
        ? path.resolve(path.dirname(source), decodeURIComponent(rawFile))
        : source;
    } catch {
      broken.push(`${path.relative(skillRoot, source)} -> ${target}`);
      return;
    }

    const relative = path.relative(skillRoot, destination);
    if (
      relative === ".." ||
      relative.startsWith(`..${path.sep}`) ||
      path.isAbsolute(relative)
    ) {
      broken.push(
        `${path.relative(skillRoot, source)} -> escapes skill root: ${target}`,
      );
      return;
    }
    if (!fs.existsSync(destination)) {
      broken.push(`${path.relative(skillRoot, source)} -> ${target}`);
      return;
    }
    if (!rawFragment || !destination.endsWith(".md")) return;

    if (!anchorCache.has(destination)) {
      anchorCache.set(
        destination,
        markdownAnchors(fs.readFileSync(destination, "utf8")),
      );
    }
    let fragment;
    try {
      fragment = decodeURIComponent(rawFragment).toLowerCase();
    } catch {
      broken.push(`${path.relative(skillRoot, source)} -> ${target}`);
      return;
    }
    if (!anchorCache.get(destination).has(fragment)) {
      broken.push(`${path.relative(skillRoot, source)} -> ${target}`);
    }
  }

  for (const source of markdownFiles) {
    const body = fs.readFileSync(source, "utf8");
    const definitions = new Map();
    for (const match of body.matchAll(
      /^\s{0,3}\[([^\]]+)\]:\s*(?:<([^>]+)>|(\S+))(?:\s+.*)?$/gm,
    )) {
      const label = normalizeReferenceLabel(match[1]);
      if (definitions.has(label)) {
        broken.push(
          `${path.relative(skillRoot, source)} -> duplicate reference [${label}]`,
        );
        continue;
      }
      const target = match[2] ?? match[3];
      definitions.set(label, target);
      validateTarget(source, target);
    }

    for (const match of body.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
      validateTarget(source, match[1]);
    }

    for (const match of body.matchAll(/(?<!!)\[([^\]\n]+)\]\[([^\]\n]*)\]/g)) {
      const label = normalizeReferenceLabel(match[2] || match[1]);
      if (!definitions.has(label)) {
        broken.push(
          `${path.relative(skillRoot, source)} -> missing reference [${label}]`,
        );
      }
    }
  }

  if (broken.length > 0) {
    fail(`broken Markdown links:\n${broken.join("\n")}`);
  }
  return markdownFiles.length;
}

function validateDeploymentMapping() {
  const skillBody = fs.readFileSync(path.join(skillRoot, "SKILL.md"), "utf8");
  const observed = new Map();
  const rowPattern =
    /^\|\s*Monad (Mainnet|Testnet)\s*\|\s*`(\d+)`\s*\(`(0x[0-9a-fA-F]+)`\)\s*\|\s*`(0x[0-9a-fA-F]{40})`\s*\|\s*`(0x[0-9a-fA-F]{40})`\s*\|\s*$/gm;
  for (const match of skillBody.matchAll(rowPattern)) {
    observed.set(match[1].toLowerCase(), {
      chainId: BigInt(match[2]),
      chainIdHex: match[3].toLowerCase(),
      proxy: match[4].toLowerCase(),
      implementation: match[5].toLowerCase(),
    });
  }

  if (observed.size !== Object.keys(NETWORKS).length) {
    fail("SKILL.md deployment table is missing or has unexpected rows");
  }
  for (const [name, expected] of Object.entries(NETWORKS)) {
    const row = observed.get(name);
    if (
      !row ||
      row.chainId !== expected.chainId ||
      row.chainIdHex !== `0x${expected.chainId.toString(16)}` ||
      row.proxy !== expected.proxy.toLowerCase() ||
      row.implementation !== expected.implementation.toLowerCase()
    ) {
      fail(`SKILL.md deployment row differs from verifier mapping: ${name}`);
    }
  }
  if (!skillBody.includes(IMPLEMENTATION_SLOT)) {
    fail("SKILL.md implementation slot differs from verifier mapping");
  }
}

function main() {
  for (const relative of requiredFiles) {
    if (!fs.existsSync(path.join(skillRoot, relative))) {
      fail(`missing required file: ${relative}`);
    }
  }
  validateDeploymentMapping();

  const bundledPath = path.join(skillRoot, "references/shmonad-abi.json");
  const artifactPath = path.join(
    repositoryRoot,
    "out/ShMonad.sol/ShMonad.json",
  );
  if (!fs.existsSync(artifactPath)) {
    fail(`missing compiled artifact: ${path.relative(repositoryRoot, artifactPath)}`);
  }

  const bundledAbi = JSON.parse(fs.readFileSync(bundledPath, "utf8"));
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  if (
    JSON.stringify(stable(bundledAbi)) !== JSON.stringify(stable(artifact.abi))
  ) {
    fail("bundled ABI differs from out/ShMonad.sol/ShMonad.json");
  }

  const expectedCounts = {
    function: 141,
    event: 79,
    error: 79,
    constructor: 1,
    receive: 1,
  };
  const observedCounts = Object.fromEntries(
    Object.keys(expectedCounts).map((type) => [
      type,
      bundledAbi.filter((item) => item.type === type).length,
    ]),
  );
  for (const [type, expected] of Object.entries(expectedCounts)) {
    if (observedCounts[type] !== expected) {
      fail(
        `unexpected ${type} count: expected ${expected}, observed ${observedCounts[type]}`,
      );
    }
  }
  const expectedTotal = Object.values(expectedCounts).reduce(
    (sum, count) => sum + count,
    0,
  );
  if (bundledAbi.length !== expectedTotal) {
    fail(
      `unexpected ABI entry count: expected ${expectedTotal}, observed ${bundledAbi.length}`,
    );
  }

  const functions = bundledAbi.filter((item) => item.type === "function");
  const signatures = functions.map(functionSignature).sort();
  const artifactIdentifiers = artifact.methodIdentifiers ?? {};
  const identifierSignatures = Object.keys(artifactIdentifiers).sort();
  if (JSON.stringify(signatures) !== JSON.stringify(identifierSignatures)) {
    fail("artifact methodIdentifiers do not cover the bundled ABI functions exactly");
  }

  const castVersion = spawnSync("cast", ["--version"], { encoding: "utf8" });
  if (castVersion.status !== 0) {
    fail("cast is required for independent selector validation");
  }
  for (const signature of signatures) {
    const result = spawnSync("cast", ["sig", signature], { encoding: "utf8" });
    if (result.status !== 0) {
      fail(`cast could not derive selector for ${signature}`);
    }
    const observed = result.stdout.trim().toLowerCase();
    const expected = `0x${artifactIdentifiers[signature]}`.toLowerCase();
    if (observed !== expected) {
      fail(
        `selector mismatch for ${signature}: artifact ${expected}, derived ${observed}`,
      );
    }
  }

  const markdownCount = validateLinks();
  console.log(
    `ShMonad skill valid: ${functions.length} functions, ` +
      `${observedCounts.event} events, ${observedCounts.error} errors, ` +
      `${markdownCount} Markdown files, all selectors and links verified.`,
  );
}

try {
  main();
} catch (error) {
  console.error(`ShMonad skill validation failed: ${error.message}`);
  process.exitCode = 1;
}
