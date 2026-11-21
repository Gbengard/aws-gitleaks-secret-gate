#!/usr/bin/env bash
# Prints a random string shaped like an AWS access key ID. It is not a real key.
# Gitleaks matches AKIA + 16 characters from A-Z and 2-7, so we use exactly that.
set -euo pipefail
while true; do
  body="$(head -c 4000 /dev/urandom | LC_ALL=C tr -dc 'A-Z2-7' | head -c 16 || true)"
  # Gitleaks ignores strings with low variety, so insist on at least 10 distinct characters.
  distinct="$(echo "${body}" | fold -w1 | sort -u | wc -l)"
  if [ "${#body}" -eq 16 ] && [ "${distinct}" -ge 10 ]; then
    echo "AKIA${body}"
    exit 0
  fi
done
