#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";

const executable = process.argv[2] ?? "/Applications/ChatGPT.app/Contents/Resources/codex";
const version = spawnSync(executable, ["--version"], { encoding: "utf8" });
console.log(`version: ${(version.stdout || version.stderr).trim()}`);

const child = spawn(executable, ["app-server"], {
  stdio: ["pipe", "pipe", "pipe"],
  env: process.env,
});
let buffer = "";
let stderr = "";
let finished = false;

function send(message) {
  child.stdin.write(`${JSON.stringify(message)}\n`);
}

function finish(exitCode) {
  if (finished) return;
  finished = true;
  clearTimeout(timer);
  child.kill();
  if (stderr.trim()) console.log(`stderr: ${stderr.trim().slice(0, 1500)}`);
  process.exitCode = exitCode;
}

function handle(message) {
  if (message.id === 1) {
    if (message.error) {
      console.log(`initialize error: ${JSON.stringify(message.error)}`);
      finish(1);
      return;
    }
    send({ method: "initialized", params: {} });
    send({ id: 2, method: "account/read", params: { refreshToken: false } });
    return;
  }
  if (message.id === 2) {
    if (message.error) {
      console.log(`account error: ${JSON.stringify(message.error)}`);
      finish(1);
      return;
    }
    const account = message.result?.account;
    console.log(`account: type=${account?.type ?? "none"}, plan=${account?.planType ?? "unknown"}`);
    send({ id: 3, method: "account/rateLimits/read" });
    return;
  }
  if (message.id === 3) {
    if (message.error) {
      console.log(`rate limits error: ${JSON.stringify(message.error)}`);
      finish(1);
      return;
    }
    const limits = message.result?.rateLimits;
    console.log(`rate limits: limit=${limits?.limitId ?? "unknown"}, primary=${limits?.primary?.usedPercent ?? "unknown"}, secondary=${limits?.secondary?.usedPercent ?? "unknown"}`);
    finish(0);
  }
}

child.stdout.on("data", (chunk) => {
  buffer += chunk.toString("utf8");
  let newline;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    if (!line.trim()) continue;
    try {
      handle(JSON.parse(line));
    } catch {
      console.log(`non-json stdout: ${line.slice(0, 500)}`);
    }
  }
});
child.stderr.on("data", (chunk) => { stderr += chunk.toString("utf8"); });
child.on("error", (error) => {
  console.log(`launch error: ${error.message}`);
  finish(1);
});
child.on("exit", (code) => {
  if (!finished) {
    console.log(`unexpected exit: ${code}`);
    finish(1);
  }
});

send({
  id: 1,
  method: "initialize",
  params: {
    clientInfo: { name: "codex_quota_probe", title: "Codex 额度 Probe", version: "1" },
    capabilities: {},
  },
});

const timer = setTimeout(() => {
  console.log("timeout after 20 seconds");
  finish(1);
}, 20_000);
