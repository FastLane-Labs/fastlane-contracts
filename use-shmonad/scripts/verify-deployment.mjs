#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath } from "node:url";

export const IMPLEMENTATION_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

export const NETWORKS = Object.freeze({
  mainnet: Object.freeze({
    chainId: 143n,
    proxy: "0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c",
    implementation: "0x856a4019228c265dee336df705277607c4a18e1b",
    rpcUrl: "https://rpc.monad.xyz",
  }),
  testnet: Object.freeze({
    chainId: 10143n,
    proxy: "0x282BdDFF5e58793AcAb65438b257Dbd15A8745C9",
    implementation: "0xbc123976c241873541eabff550724a9adfc4651d",
    rpcUrl: "https://testnet-rpc.monad.xyz",
  }),
});

function fail(message) {
  throw new Error(message);
}

function requireQuantity(value, label) {
  if (
    typeof value !== "string" ||
    !/^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/.test(value)
  ) {
    fail(`${label} is not a canonical RPC quantity`);
  }
  return value;
}

function requireData(value, label) {
  if (typeof value !== "string" || !/^0x(?:[0-9a-fA-F]{2})*$/.test(value)) {
    fail(`${label} is not canonical RPC data`);
  }
  return value;
}

function requireWord(value, label) {
  const data = requireData(value, label);
  if (!/^0x[0-9a-fA-F]{64}$/.test(data)) {
    fail(`${label} is not a 32-byte ABI word`);
  }
  return data;
}

function decodeUint256(value, label) {
  return BigInt(requireWord(value, label));
}

function decodeString(value, label) {
  const hex = requireData(value, label).slice(2);
  if (hex.length < 128 || hex.length % 64 !== 0) {
    fail(`${label} is not a canonical ABI string result`);
  }

  const offset = BigInt(`0x${hex.slice(0, 64)}`);
  if (offset !== 32n) {
    fail(`${label} does not use the canonical single-return string offset`);
  }

  const length = Number(BigInt(`0x${hex.slice(64, 128)}`));
  if (!Number.isSafeInteger(length)) {
    fail(`${label} contains an unsupported ABI string length`);
  }
  const paddedHexLength = Math.ceil(length / 32) * 64;
  if (hex.length !== 128 + paddedHexLength) {
    fail(`${label} contains noncanonical ABI string bounds`);
  }

  const dataEnd = 128 + length * 2;
  if (!/^0*$/.test(hex.slice(dataEnd))) {
    fail(`${label} contains nonzero ABI string padding`);
  }

  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(
      Buffer.from(hex.slice(128, dataEnd), "hex"),
    );
  } catch {
    fail(`${label} is not valid UTF-8`);
  }
}

function displayEndpoint(rpcUrl) {
  try {
    const url = new URL(rpcUrl);
    url.username = "";
    url.password = "";
    url.search = "";
    url.hash = "";
    return url.toString();
  } catch {
    return rpcUrl;
  }
}

async function main() {
  const [networkName, rpcOverride, ...extra] = process.argv.slice(2);
  const network = NETWORKS[networkName];
  if (!network || extra.length > 0) {
    fail(
      "usage: node scripts/verify-deployment.mjs <mainnet|testnet> [rpc-url]",
    );
  }

  const rpcUrl = rpcOverride ?? network.rpcUrl;
  const context = {
    network: networkName,
    endpoint: displayEndpoint(rpcUrl),
    proxy: network.proxy,
    block: "unavailable",
  };

  try {
    let requestId = 0;
    async function rpc(method, params) {
      const id = ++requestId;
      const response = await fetch(rpcUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
        signal: AbortSignal.timeout(20_000),
      });
      if (!response.ok) {
        fail(`${method} returned HTTP ${response.status}`);
      }
      const payload = await response.json();
      if (
        !payload ||
        Array.isArray(payload) ||
        payload.jsonrpc !== "2.0" ||
        payload.id !== id
      ) {
        fail(`${method} returned a mismatched JSON-RPC envelope`);
      }
      if (payload.error != null) {
        fail(`${method} failed: ${JSON.stringify(payload.error)}`);
      }
      if (!Object.hasOwn(payload, "result")) {
        fail(`${method} returned no result`);
      }
      return payload.result;
    }

    const chainIdHex = requireQuantity(
      await rpc("eth_chainId", []),
      "chain ID",
    );
    const observedChainId = BigInt(chainIdHex);
    if (observedChainId !== network.chainId) {
      fail(
        `chain mismatch: expected ${network.chainId}, observed ${observedChainId}`,
      );
    }

    const block = requireQuantity(
      await rpc("eth_blockNumber", []),
      "block number",
    );
    context.block = block;
    const proxyCode = requireData(
      await rpc("eth_getCode", [network.proxy, block]),
      "proxy code",
    );
    if (proxyCode === "0x") fail(`no code at proxy ${network.proxy}`);

    const implementationWord = requireWord(
      await rpc("eth_getStorageAt", [
        network.proxy,
        IMPLEMENTATION_SLOT,
        block,
      ]),
      "implementation slot",
    );
    if (!/^0x0{24}[0-9a-fA-F]{40}$/.test(implementationWord)) {
      fail("implementation slot is not a canonically encoded address");
    }
    const observedImplementation = `0x${implementationWord.slice(-40)}`;
    if (
      observedImplementation.toLowerCase() !==
      network.implementation.toLowerCase()
    ) {
      fail(
        `implementation mismatch: expected ${network.implementation}, observed ${observedImplementation}`,
      );
    }

    const implementationCode = requireData(
      await rpc("eth_getCode", [observedImplementation, block]),
      "implementation code",
    );
    if (implementationCode === "0x") {
      fail(`no code at implementation ${observedImplementation}`);
    }

    async function call(selector) {
      return rpc("eth_call", [{ to: network.proxy, data: selector }, block]);
    }

    const name = decodeString(await call("0x06fdde03"), "name()");
    const symbol = decodeString(await call("0x95d89b41"), "symbol()");
    const decimals = decodeUint256(await call("0x313ce567"), "decimals()");
    if (decimals > 255n) fail("decimals() does not fit uint8");
    if (name !== "ShMonad" || symbol !== "shMON" || decimals !== 18n) {
      fail(
        `metadata mismatch: observed ${JSON.stringify({ name, symbol, decimals: decimals.toString() })}`,
      );
    }

    console.log(
      JSON.stringify(
        {
          network: networkName,
          chainId: observedChainId.toString(),
          block,
          proxy: network.proxy,
          implementation: observedImplementation,
          name,
          symbol,
          decimals: Number(decimals),
        },
        null,
        2,
      ),
    );
  } catch (error) {
    fail(`${error.message}; context=${JSON.stringify(context)}`);
  }
}

const directRun =
  process.argv[1] &&
  path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));

if (directRun) {
  main().catch((error) => {
    console.error(`ShMonad deployment verification failed: ${error.message}`);
    process.exitCode = 1;
  });
}
