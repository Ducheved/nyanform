#!/usr/bin/env node

const fs = require("fs");

const inputPath = process.argv[2];
const seconds = Number(process.argv[3]);

process.stdout.write(fs.readFileSync(inputPath));
setTimeout(() => {}, seconds * 1000);
