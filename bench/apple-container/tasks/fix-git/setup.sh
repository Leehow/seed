#!/bin/sh
set -eu
ws=$1
if ! command -v git >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends git
fi
cd "$ws"
git config --global user.email 'bench@example.com'
git config --global user.name 'bench'
git config --global init.defaultBranch master
git init
printf '<h1>v1</h1>\n' > index.html
git add index.html
git commit -m 'initial site'
git checkout -b wip
printf '<h1>secret-change-42</h1>\n' > index.html
git add index.html
git commit -m 'wip: new heading'
git checkout master
