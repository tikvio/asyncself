"use strict";

const readline = require("node:readline");

const output = (payload) => process.stdout.write(`${JSON.stringify(payload)}\n`);

readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const request = JSON.parse(line);
  if (request.method === "initialize") {
    output({ jsonrpc: "2.0", id: request.id, result: { protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo: { name: "asyncself-fixture", version: "1" } } });
  } else if (request.method === "tools/list") {
    output({ jsonrpc: "2.0", id: request.id, result: { tools: [] } });
  } else if (Object.prototype.hasOwnProperty.call(request, "id")) {
    output({ jsonrpc: "2.0", id: request.id, error: { code: -32601, message: "unsupported" } });
  }
});
