#!/usr/bin/env bash
# common/build-glorytun.sh — compila e instala o glorytun (rodar no router E na VPS).
set -euo pipefail

sudo apt update
sudo apt install -y build-essential git autoconf automake pkg-config libsodium-dev

tmp="$(mktemp -d)"
cd "$tmp"
git clone https://github.com/angt/glorytun
cd glorytun
git submodule update --init --recursive
./autogen.sh
./configure
make -j"$(nproc)"
sudo make install
sudo mkdir -p /etc/glorytun

echo "glorytun instalado em:"
command -v glorytun-tcp || command -v glorytun || echo "  (binário não encontrado no PATH — verifique make install)"
