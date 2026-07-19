# DEPRECATED — nginx stream SNI (legacy)

> **Prefer HAProxy SSL-terminate** (real client IP in MDM Devices):
> `scripts/single-port/setup-single-port.sh` or `migrate-nginx-to-haproxy.sh`
> See `scripts/single-port/README.md`.

The files in this folder document the old **TCP/SNI passthrough** design. It cannot
inject `X-Real-IP`, so Devices often show `172.18.0.1` (Docker gateway).

Kept for rollback only. Templates also live under
`scripts/single-port/templates/sni-443.conf.template`.
