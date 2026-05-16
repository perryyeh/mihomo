# mihomo

Mihomo deployment templates for Armbian/dockerapps.

## Roles

- `config.host.yaml`: inbound/central `mihomoin` style configuration. It is intended for `network_mode: host`, listens for branch-site upstream traffic, and should not run transparent TUN routing.
- `config.macvlan.yaml`: outbound/branch-site `mihomo` style configuration. It is intended for macvlan deployment, provides DNS/fake-ip/TUN transparent routing, and uses upstream proxy nodes for non-direct traffic.

## Compose templates

- `docker-compose.host.yml`: host-network compose template.
- `docker-compose.macvlan.yml`: macvlan compose template using `${ipv4}`, `${ipv6}`, `${macaddress}`, and `${MACVLAN_NET}`.

Both compose templates set `TZ: Asia/Singapore` and mount the host timezone files read-only:

```yaml
- /etc/localtime:/etc/localtime:ro
- /etc/timezone:/etc/timezone:ro
```

## Deployment convention

- Do not commit a generated production `config.yaml`.
- Copy the selected template to `config.yaml` during deployment.
- Do not commit real proxy nodes, UUIDs, passwords, tokens, dashboard secrets, or site-specific credentials.
- Keep real node definitions and secrets in local deployment files only.

## Fake-IP / `198.18.0.0/15` note

Branch `config.macvlan.yaml` uses fake-ip for transparent routing. A central inbound `config.host.yaml` may receive connections whose resolved remote destination is in `198.18.0.0/15`; those addresses are fake-ip targets and must not be sent to `DIRECT`. Route `198.18.0.0/15` to the selected upstream group instead.

## Probe URL convention

- `config.host.yaml` inbound/central fallback probes should prefer a domestic URL: `http://connect.rom.miui.com/generate_204`.
- `config.macvlan.yaml` outbound/branch url-test probes should default to `http://www.gstatic.com/generate_204`.
- Exception: if a branch's upstream is domestic or centrally hosted in China, use the MIUI URL for that branch deployment, as with tx/tv using the SH upstream.

## QUIC / HTTP/3 blocking note

When blocking QUIC, use a UDP-only rule:

```yaml
AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
```

Do not use a bare `DST-PORT,443,REJECT`, because that would also block normal TCP/443 HTTPS.