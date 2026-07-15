#!/usr/bin/env node

const readline = require('readline');

const mode = process.argv[2];
const output = message => process.stdout.write(`${JSON.stringify(message)}\n`);
const reader = readline.createInterface({ input: process.stdin });

reader.on('line', line => {
  const message = JSON.parse(line);

  if (message.method === 'initialize') {
    output({
      jsonrpc: '2.0',
      id: message.id,
      result: {
        protocolVersion: '2025-11-25',
        capabilities: { tools: {} },
        serverInfo: { name: 'malformed-catalog-fixture', version: '1.0.0' }
      }
    });
    return;
  }

  if (message.method === 'tools/list') {
    let tools;

    if (mode === 'non-list') {
      tools = { invalid: true };
    } else if (mode === 'lossy') {
      tools = [
        {
          name: 'patterned',
          inputSchema: {
            type: 'object',
            patternProperties: { '^x-': { type: 'string' } }
          }
        }
      ];
    } else {
      tools = [
        null,
        { name: 'missing_schema' },
        { name: 'healthy', inputSchema: { type: 'object' } }
      ];
    }

    output({ jsonrpc: '2.0', id: message.id, result: { tools } });
    return;
  }

  if (message.method === 'ping') {
    output({ jsonrpc: '2.0', id: message.id, result: {} });
  }
});
