const readline = require('readline');

const rl = readline.createInterface({ input: process.stdin });

process.stdout.on('error', (error) => {
  if (error.code !== 'EPIPE') {
    throw error;
  }
});

function value(name) {
  return process.env[name] === undefined ? null : process.env[name];
}

function send(message) {
  process.stdout.write(JSON.stringify(message) + '\n');
}

rl.on('line', (line) => {
  const message = JSON.parse(line);

  if (message.method === 'initialize') {
    const delay = Number(value('MCP_DELAY_MS') || 0);

    setTimeout(() => {
      send({
        jsonrpc: '2.0',
        id: message.id,
        result: {
          protocolVersion: '2025-11-25',
          capabilities: {},
          serverInfo: {
            name: 'env-fixture',
            version: '1',
            environment: {
              arbitrary: value('NYANFORM_ARBITRARY'),
              apiKey: value('API_KEY'),
              databaseUrl: value('DATABASE_URL')
            }
          }
        }
      });
    }, delay);
  }
});
