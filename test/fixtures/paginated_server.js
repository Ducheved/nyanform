#!/usr/bin/env node

const readline = require('readline');

const protocolVersion = '2025-11-25';

const pages = {
  first: {
    tools: [
      {
        name: 'collision name',
        description: 'Tool from the first page',
        inputSchema: { type: 'object', properties: {} }
      }
    ],
    nextCursor: 'page-2'
  },
  second: {
    tools: [
      {
        name: 'collision_name',
        description: 'Tool from the second page',
        inputSchema: { type: 'object', properties: {} }
      }
    ]
  }
};

const output = message => process.stdout.write(`${JSON.stringify(message)}\n`);

const reader = readline.createInterface({ input: process.stdin });

reader.on('line', line => {
  let message;

  try {
    message = JSON.parse(line);
  } catch (_error) {
    return;
  }

  if (message.method === 'initialize') {
    output({
      jsonrpc: '2.0',
      id: message.id,
      result: {
        protocolVersion,
        capabilities: { tools: {} },
        serverInfo: { name: 'paginated-fixture', version: '1.0.0' }
      }
    });
    return;
  }

  if (message.method === 'tools/list') {
    const cursor = message.params && message.params.cursor;

    if (cursor === undefined) {
      output({ jsonrpc: '2.0', id: message.id, result: pages.first });
      return;
    }

    if (cursor === 'page-2') {
      output({ jsonrpc: '2.0', id: message.id, result: pages.second });
      return;
    }

    output({
      jsonrpc: '2.0',
      id: message.id,
      error: { code: -32602, message: `unexpected cursor: ${String(cursor)}` }
    });
    return;
  }

  if (message.method === 'tools/call') {
    const name = message.params && message.params.name;

    if (name === 'collision name' || name === 'collision_name') {
      output({
        jsonrpc: '2.0',
        id: message.id,
        result: { content: [{ type: 'text', text: `called ${name}` }] }
      });
      return;
    }
  }

  if (message.id !== undefined) {
    output({
      jsonrpc: '2.0',
      id: message.id,
      error: { code: -32601, message: 'method not found' }
    });
  }
});
