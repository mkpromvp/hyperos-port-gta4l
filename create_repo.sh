#!/bin/bash
# Usage: GITHUB_TOKEN=your_token ./create_repo.sh
TOKEN="${GITHUB_TOKEN:?Set GITHUB_TOKEN env var}"
curl -s -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/user/repos" \
  -d '{"name":"hyperos-port-gta4l","description":"HyperOS 1.0 Port for SM-T505N","private":false}'
