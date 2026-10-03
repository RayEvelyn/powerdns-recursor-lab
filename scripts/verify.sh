#!/usr/bin/env bash
set -euo pipefail
command -v dig >/dev/null || { echo 'Install dig first.' >&2; exit 1; }
# A deliberately broken DNSSEC zone must be rejected by validation.
dig @127.0.0.1 -p 15355 example.com A | grep -q 'status: NOERROR'
dig @127.0.0.1 -p 15355 example.com A +tcp | grep -q 'status: NOERROR'
dig @127.0.0.1 -p 15355 dnssec-failed.org A | grep -q 'status: SERVFAIL'
echo 'Verified public recursion, TCP fallback and DNSSEC rejection.'
