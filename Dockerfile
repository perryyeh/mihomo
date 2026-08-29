FROM metacubex/mihomo:latest

# Full-configuration subscriptions are structurally patched inside the
# container, so this runtime deliberately carries only the required tools.
RUN apk add --no-cache curl python3 py3-yaml
