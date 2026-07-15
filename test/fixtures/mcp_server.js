#!/usr/bin/env node

const readline = require('readline');

const PROTOCOL_VERSION = '2025-11-25';

const tools = [
  {
    name: 'portable_tool',
    description: 'A fully portable tool with a simple object schema',
    inputSchema: {
      type: 'object',
      properties: {
        message: { type: 'string', minLength: 1, maxLength: 100 }
      },
      required: ['message']
    }
  },
  {
    name: 'union_tool',
    description: 'A tool using oneOf for polymorphic input',
    inputSchema: {
      oneOf: [
        {
          type: 'object',
          properties: {
            kind: { type: 'string', const: 'text' },
            content: { type: 'string' }
          },
          required: ['kind', 'content']
        },
        {
          type: 'object',
          properties: {
            kind: { type: 'string', const: 'number' },
            value: { type: 'number' }
          },
          required: ['kind', 'value']
        }
      ]
    }
  },
  {
    name: 'nullable_array_tool',
    description: 'A tool with a nullable array property',
    inputSchema: {
      type: 'object',
      properties: {
        tags: {
          type: ['array', 'null'],
          items: { type: 'string' }
        }
      }
    }
  },
  {
    name: 'defs_tool',
    description: 'A tool using local $defs and $ref',
    inputSchema: {
      type: 'object',
      properties: {
        node: { $ref: '#/$defs/Node' }
      },
      $defs: {
        Node: {
          type: 'object',
          properties: {
            value: { type: 'string' }
          }
        }
      }
    }
  },
  {
    name: 'closed_object_tool',
    description: 'A tool with additionalProperties false',
    inputSchema: {
      type: 'object',
      properties: {
        x: { type: 'string' },
        y: { type: 'integer' }
      },
      additionalProperties: false
    }
  },
  {
    name: 'recursive_tool',
    description: 'A tool containing a recursive schema',
    inputSchema: {
      type: 'object',
      properties: {
        tree: { $ref: '#/$defs/Tree' }
      },
      $defs: {
        Tree: {
          type: 'object',
          properties: {
            value: { type: 'string' },
            children: {
              type: 'array',
              items: { $ref: '#/$defs/Tree' }
            }
          }
        }
      }
    }
  },
  {
    name: 'invalid_array_tool',
    description: 'A tool with an array missing items',
    inputSchema: {
      type: 'object',
      properties: {
        data: { type: 'array' }
      }
    }
  },
  {
    name: 'read-file',
    description: 'Tool name with a hyphen that may collide',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string' }
      }
    }
  },
  {
    name: 'read_file',
    description: 'Tool name with underscore that may collide after sanitization',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string' }
      }
    }
  },
  {
    name: 'nested_json_tool',
    description: 'A tool expecting a nested object that may arrive as a JSON string',
    inputSchema: {
      type: 'object',
      properties: {
        config: {
          type: 'object',
          properties: {
            key: { type: 'string' },
            value: { type: 'string' }
          }
        }
      }
    }
  }
];

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

function handleMessage(line) {
  if (!line || line.trim() === '') return;

  let msg;
  try {
    msg = JSON.parse(line);
  } catch (e) {
    sendError(null, -32700, 'Parse error: ' + e.message);
    return;
  }

  if (msg.method === 'initialize') {
    sendResponse(msg.id, {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: { tools: { listChanged: true } },
      serverInfo: { name: 'nyanform-fixture-server', version: '0.1.0' }
    });
  } else if (msg.method === 'notifications/initialized') {
  } else if (msg.method === 'tools/list') {
    sendResponse(msg.id, { tools: tools });
  } else if (msg.method === 'tools/call') {
    const name = msg.params && msg.params.name;
    const args = (msg.params && msg.params.arguments) || {};

    if (name === 'nested_json_tool' && typeof args.config === 'object') {
      sendResponse(msg.id, {
        content: [{ type: 'text', text: 'config received: ' + JSON.stringify(args.config) }]
      });
    } else if (name === 'portable_tool') {
      sendResponse(msg.id, {
        content: [{ type: 'text', text: 'echo: ' + (args.message || '') }]
      });
    } else {
      sendResponse(msg.id, {
        content: [{ type: 'text', text: 'called ' + name + ' with ' + JSON.stringify(args) }]
      });
    }
  } else if (msg.method === 'ping') {
    sendResponse(msg.id, {});
  } else if (msg.id !== undefined) {
    sendError(msg.id, -32601, 'Method not found: ' + msg.method);
  }
}

function sendResponse(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: id, result: result }) + '\n');
}

function sendError(id, code, message) {
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: id, error: { code: code, message: message } }) + '\n');
}

rl.on('line', handleMessage);
rl.on('close', () => process.exit(0));
