#!/usr/bin/env sh
set -eu

cd /app
npm install --no-audit --no-fund
mkdir -p dist/
npx gulp
