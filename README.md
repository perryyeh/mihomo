# mihomo

用于 Armbian/dockerapps 的 Mihomo 部署模板。

## 角色

- `config.host.yaml`：纯入站/回家端 `mihomoin` 配置。适用于 `network_mode: host`，接收分支站点流量后按宿主机所在局域网的正常路由直接出站；不启用透明 TUN 路由、DNS、代理节点、代理组或分流规则。
- `config.macvlan.yaml`：出站/分支端 `mihomo` 风格配置。适用于 macvlan 部署，提供 DNS/Fake-IP/TUN 透明路由；非直连流量通过上游代理节点转发。

## Compose 模板

- `docker-compose.host.yml`：host 网络模式的 Compose 模板。
- `docker-compose.macvlan.yml`：macvlan Compose 模板，使用 `${ipv4}`、`${ipv6}`、`${macaddress}` 与 `${MACVLAN}`。

两个 Compose 模板都直接运行官方 `metacubex/mihomo:latest`，不构建本地派生镜像。`entrypoint.sh` 是稳定的 PID 1 加载器；可选行为均放在配置目录中的 `entrypoint.d/*.sh`，不会再修改 Compose 的 `entrypoint`。订阅更新实际执行时若缺少 `curl`、`python3` 或 `py3-yaml`，才在容器内通过 `apk` 安装。

### 可选启动模块

- `entrypoint.d/10-network-policy.sh`：读取同目录 `.env` 的 `ipv4/gateway`、`ipv42/gateway2`、`ipv43/gateway3`…；只有声明至少两张 macvlan 时才启用。脚本按 IPv4 地址定位实际接口，自动分配从 `101` 开始的路由表，建立 IPv4 源地址策略路由；接口存在公网 IPv6 与 RA 默认网关时，同时建立 IPv6 策略路由。第一张网络为主默认出口。
- `entrypoint.d/30-subscription-schedule.sh`：仅存在 `subscription.conf` 且更新间隔至少为 1 小时时启用。Mihomo 首先启动并监听服务，随后异步调用同目录 `subscription.sh` 执行一次更新，再按周期更新。订阅下载、`apk` 依赖安装或网络失败都不会阻塞 Mihomo 启动；间隔为 `0` 时关闭自动刷新，可从 YehBP 手动更新。订阅的 `listeners` 含 `certificate` 或 `private-key` 时，更新器固定从订阅 URL 同目录下载 `server.crt` 和 `server.key`，保存到配置目录，并将监听器路径规范为 `./server.crt`、`./server.key`；下载失败时保留本地证书但仍规范化订阅配置路径。
- `mihomo.args`：可选，一行一个额外 Mihomo 参数。例如可保留自定义 `-post-up` 逻辑；文件不存在时仅运行 `/mihomo -d /root/.config/mihomo`。

因此，单网卡、未配置订阅的部署不改路由、不执行订阅任务；多网卡策略由用户在 `.env` 与 Compose 中增加网络信息后自动处理，订阅调度为独立可删的配置目录模块。

```yaml
- /etc/localtime:/etc/localtime:ro
- /etc/timezone:/etc/timezone:ro
```

## 部署约定

- 不提交运行环境生成的 `config.yaml`。
- 部署时将选定模板复制为 `config.yaml`。
- `subscription.macvlan.yaml` 是 macvlan 完整订阅的结构化覆盖层：更新器递归覆盖其中的本地部署字段，包含强制写入的 `dns.fake-ip-range`；仅 `dns.fake-ip-range6` 会在上游已定义时才覆盖，不会凭空添加。
- YehBP 安装时按选定模板的 `external-ui` 与 `external-ui-url` 下载最新 tar.gz UI 并原子写入该目录；本仓库不再提交 UI 静态文件。手动部署时需自行下载该 URL 的内容到 `external-ui` 所指定目录。
- 不提交真实代理节点、UUID、密码、Token、面板密钥或站点专属凭据。
- 真实节点定义与密钥只保存在本地部署文件中。

## 分支端 Fake-IP 说明

分支端 `config.macvlan.yaml` 使用 Fake-IP 实现透明路由。纯入站的 `config.host.yaml` 不维护 Fake-IP 映射，也不做二次代理或分流；回家流量由宿主机所在局域网的正常路由处理。

分支端 IPv6 Fake-IP 中，`config.macvlan.yaml` 会启用 TUN IPv6 地址及 IPv6 Fake-IP 池：

```yaml
tun:
  inet6-address:
    - fdfe:dcba:9876::1/126

dns:
  fake-ip-range6: 2001:2:0:6152:0:9::/96
```

Mihomo 会从 `2001:2:0:6152:0:9::/96` 生成 IPv6 Fake-IP 应答。周边路由器/站点策略应将汇总段 `2001:2:0:6152::/64` 路由至 Mihomo 实例；该汇总段同时覆盖 VIF gateway 与 Fake DNS 地址。

## DNS 与泄漏边界

- 当前置部署 mosdns 时，mihomo 不负责上游域名分类；应由 mosdns 决定域名走直连、代理或 Fake-IP。
- mihomo 仍应控制：
  - UDP 443 / QUIC 行为。
  - 规则适用范围内的 WebRTC / STUN / TURN 暴露。
  - 自身 DNS 上游，避免代理流量意外经本地 ISP DNS 解析。
- 分支端 DNS 可能返回 Fake-IP 时，Fake-IP CIDR 不能落入普通 `DIRECT`；应路由至预期的上游策略组。

## 模板与运行态约定

- 模板配置使用如 `10.0.0.1` 的占位网关地址。
- 运行态配置可能需要替换为部署站点真实 LAN 网关。
- 不要将真实密钥、节点、UUID、密码、Token 或面板密钥从运行态回写到此公开模板仓库。
- 将运行态修复同步回模板时，应优先做 DNS/TUN/规则等最小节级修改；不要把运行态节点或策略组数据覆盖进仓库。

## DNS 泄漏修复模式

对于 BrowserLeaks 一类“最终流量已代理，但探测域名仍经本地 ISP DNS 解析”的 DNS 泄漏：

- 适用时确保启用 `respect-rules: true`。
- 将 bootstrap/直连侧解析器与代理域名解析器分离。
- 海外/代理域名查询按部署需要使用加密或经代理的上游。
- 国内解析器仅用于直连或 bootstrap 场景。
- 通过日志验证探测域名不再意外命中本地网关或明文 UDP DNS。

## 探测 URL 约定

- `config.macvlan.yaml` 的出站/分支端 url-test 默认使用 `http://www.gstatic.com/generate_204`。
- 例外：分支上游位于国内或集中部署在国内时，该分支应使用 MIUI URL。

## QUIC / HTTP/3 阻断说明

阻断 QUIC 时，应使用仅匹配 UDP 的规则：

```yaml
AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
```

不要使用裸 `DST-PORT,443,REJECT`，否则也会阻断正常的 TCP/443 HTTPS。
