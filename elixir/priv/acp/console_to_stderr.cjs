"use strict";

// This module is loaded only into the ACP launcher process with Node's
// `--require` flag.  ACP owns stdout for JSON-RPC, while dsh account discovery
// currently uses console.info for diagnostics.  Do not set NODE_OPTIONS: it
// would leak this policy to model/tool subprocesses.
const { format } = require("node:util");

const write = (...args) => {
  try {
    process.stderr.write(`${format(...args)}\n`);
  } catch (_) {
    // Diagnostics must never affect ACP protocol delivery.
  }
};

for (const method of ["log", "info", "debug", "warn", "error", "dir", "trace"]) {
  console[method] = (...args) => write(...args);
}
