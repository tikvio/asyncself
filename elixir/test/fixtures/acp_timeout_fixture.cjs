"use strict";

const mode = process.env.ASYNCSELF_FAKE_ACP_MODE || "silence";
const { spawn } = require("node:child_process");
const childPidPath = process.env.ASYNCSELF_FAKE_ACP_CHILD_PID_PATH;
let tick;
let activePromptId;
let pendingClientRequestId;
const out = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);

if (mode === "child") {
  const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
  if (childPidPath) require("node:fs").writeFileSync(childPidPath, String(child.pid));
}

process.stdin.setEncoding("utf8");
let buffer = "";
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  for (;;) {
    const index = buffer.indexOf("\n");
    if (index < 0) return;
    const line = buffer.slice(0, index);
    buffer = buffer.slice(index + 1);
    const request = JSON.parse(line);
    if (request.method === "initialize") {
      if (mode === "handshake_invalid") process.stdout.write("not-json\n");
      else out({ jsonrpc: "2.0", id: request.id, result: {} });
    }
    if (request.method === "session/new") out({ jsonrpc: "2.0", id: request.id, result: mode === "handshake_missing" ? {} : { sessionId: "fixture" } });
    if (request.method === "session/close") out({ jsonrpc: "2.0", id: request.id, result: {} });
    if (request.method === "session/cancel" && activePromptId) {
      clearInterval(tick);
      out({ jsonrpc: "2.0", id: activePromptId, result: { stopped: true } });
    }
    if (request.method === "session/prompt") {
      activePromptId = request.id;
      if (mode === "exit") process.exit(17);
      if (mode === "error") return out({ jsonrpc: "2.0", id: request.id, error: { code: -32000, message: "fixture error" } });
      if (mode === "invalid") return process.stdout.write("not-json\n");
      if (mode === "permission") {
        pendingClientRequestId = 90;
        return out({ jsonrpc: "2.0", id: pendingClientRequestId, method: "session/request_permission", params: {} });
      }
      if (mode === "unknown_request") {
        pendingClientRequestId = 91;
        return out({ jsonrpc: "2.0", id: pendingClientRequestId, method: "fixture/unknown", params: {} });
      }
      if (mode === "silence") continue;
      const type = mode === "progress" ? "tool_call" : "thought";
      tick = setInterval(() => out({ jsonrpc: "2.0", method: "session/update", params: { update: { sessionUpdate: { type } } } }), 8);
    }
    if (request.id === pendingClientRequestId) {
      pendingClientRequestId = undefined;
      out({ jsonrpc: "2.0", id: activePromptId, result: { handled: true } });
    }
  }
});
process.on("exit", () => clearInterval(tick));
