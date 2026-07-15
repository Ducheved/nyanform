#!/usr/bin/env node

const readline = require("readline");

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

process.stdout.on("error", () => process.exit(0));

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

rl.on("line", (line) => {
  const message = JSON.parse(line);

  if (message.method === "initialize") {
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        protocolVersion: "2025-11-25",
        capabilities: { tools: {} },
        serverInfo: { name: "push-fixture", version: "1.0.0" }
      }
    });

    setTimeout(() => {
      send({
        jsonrpc: "2.0",
        method: "notifications/progress",
        params: { progress: 1, total: 1 }
      });
    }, 200);
  } else if (message.method === "tools/list") {
    send({jsonrpc: "2.0", id: message.id, result: {tools: []}});
  }
});
