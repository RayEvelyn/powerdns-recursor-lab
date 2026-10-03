#!/usr/bin/env bash
set -euo pipefail
command -v dig >/dev/null || { echo 'Install dig first.' >&2; exit 1; }
# A deliberately broken DNSSEC zone must be rejected by validation.
answer=$(dig @127.0.0.1 -p 15355 example.com A +time=3 +tries=1)
grep -q 'status: NOERROR' <<< "$answer"
grep -Eq '[[:space:]]IN[[:space:]]+A[[:space:]]+[0-9]+\.' <<< "$answer"
answer_tcp=$(dig @127.0.0.1 -p 15355 example.com A +tcp +time=3 +tries=1)
grep -q 'status: NOERROR' <<< "$answer_tcp"
grep -Eq '[[:space:]]IN[[:space:]]+A[[:space:]]+[0-9]+\.' <<< "$answer_tcp"
dig @127.0.0.1 -p 15355 dnssec-failed.org A | grep -q 'status: SERVFAIL'
echo 'Verified public recursion, TCP fallback and DNSSEC rejection.'
