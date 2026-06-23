# HERMES.md

Repository-local conventions for this mihomo template repo.

## Compose env naming

For dual-macvlan / multi-NIC mihomo deployments, keep these env names stable across templates and deployment scripts:

- `ipv4` / `ipv6`: primary macvlan address pair.
- `ipv42` / `ipv62`: secondary macvlan address pair.
- `macaddress` / `macaddress2`: MAC addresses matching the primary/secondary macvlan address pairs.

Do not encode private site names, live node secrets, UUIDs, passwords, tokens, or real production proxy definitions in this public repo. Runtime deployment files may substitute site-specific gateway/interface values locally.
