# CN Guard — 中国大陆 IP 入站白名单

面向 Debian 13 / nftables（包括 `iptables-nft`）的独立 nftables 表方案。目标是限制从公网接口进入主机和转发路径的新连接，只接受 IPdeny 中国大陆 IPv4/IPv6 地址库中的来源地址。

> **生产环境警告：** 本项目会修改运行中的防火墙。首次应用会设置限时自动回滚，但仍可能影响 SSH、Docker 发布端口、Realm 转发或其他业务。请先使用云厂商控制台/VNC 作为备用入口，审阅配置和脚本，并在测试机验证。不要在没有带外恢复方式的生产机上盲目运行。

## 功能

- 不执行 `iptables -F` 或 `nft flush ruleset`。
- 只创建/更新独立的 `inet cn_guard` 表，不主动删除 Docker、`YJ-FIREWALL-INPUT` 或其他现有表/链。
- 使用 IPv4 与 IPv6 中国地址库；下载后验证 CIDR 格式、地址族和最小条目数量。
- 在应用前检查当前管理 IP 是否存在于对应地址库；不自动加入海外管理地址例外。
- 首次应用前备份 nftables、iptables、接口/路由和监听端口状态。
- 首次应用使用默认 15 分钟自动回滚；通过新 SSH 会话和业务测试后，运行 `cn-guard confirm` 才持久化。
- 每日定时更新地址库。
- `cn-guard rollback` 仅删除本项目的 `inet cn_guard` 表，并禁用本项目服务/定时器。

## 快速开始

先下载到本地文件再执行（不要使用 `curl | bash`，安装器需要将自身复制为管理命令）：

```bash
curl -fsSLo install-cn-guard.sh https://raw.githubusercontent.com/xiaofujie369/-IP-/main/install-cn-guard.sh
sudo bash install-cn-guard.sh
```

默认执行流程：安装命令 → 备份 → 下载并验证地址库 → 检查管理 IP → 语法校验 → 应用临时规则 → 启动 15 分钟回滚计时器。

若要只安装管理命令而不修改防火墙：

```bash
sudo bash install-cn-guard.sh --install-only
```

> 如果使用 `sudo` 导致 `SSH_CONNECTION` 未传入，安装前请确认自己的公网出口 IP，然后显式传入：
>
> ```bash
> sudo env ADMIN_IP=你的公网出口IP bash install-cn-guard.sh
> ```
>
> 该地址仍必须出现在 IPdeny 中国大陆地址库中，否则脚本拒绝应用。不要为了绕过检查而伪造管理 IP。

## 应用后必须完成的测试

1. 保持原 SSH 会话，不要关闭。
2. 从当前管理网络另开一个全新 SSH 连接；旧连接可能因 conntrack 仍然存活，不能证明新连接可用。
3. 从中国大陆网络测试需要公开的 TCP/UDP 端口。
4. 从非中国大陆网络测试新建连接应被拦截。
5. 测试 Realm 的 TCP/UDP `60078`、`26474`，以及用途尚未确认的 TCP `22331`。
6. 检查所有 Docker 发布端口、容器健康状态、IPv4/IPv6 连接和云厂商安全组。
7. 只有全部测试通过后才运行：

```bash
sudo cn-guard confirm
```

如果测试失败，立即执行 `sudo cn-guard rollback`，或者保持会话不动等待自动回滚。回滚只删除 `inet cn_guard`，不会清空其他防火墙规则。

## 管理命令

```bash
sudo cn-guard status    # 查看规则、计时器和地址库更新时间
sudo cn-guard backup    # 手动备份当前规则与网络状态
sudo cn-guard update    # 手动更新地址库并尝试应用
sudo cn-guard rollback  # 撤销本项目规则与服务
```

配置文件：`/etc/cn-guard.conf`

- `ADMIN_IPS`：管理来源地址列表。每个地址都必须属于中国大陆地址库。
- `WAN_IFS`：公网入口接口名，默认自动检测 IPv4/IPv6 默认路由接口。多接口时用空格分隔。
- `LOCAL_V4`：默认空。仅在确实需要信任特定入口私网来源时才配置；配置错误可能绕过来源限制。
- `ROLLBACK_MIN`：首次应用的自动回滚分钟数，默认 15。

## 重要限制与已知风险

- IP 地理归属库存在误差，不等于实际用户地理位置证明。IPdeny 数据库可能包含/遗漏某些地址段；请核实其当前数据与“中国大陆”的业务定义。
- 中国大陆以外的 SSH 管理地址会被拒绝；没有自动海外例外。海外网络维护需要先设计独立且符合安全目标的管理路径。
- 当前规则针对从配置的 WAN 接口进入的 INPUT 和 FORWARD 流量。云厂商安全组、上游 NAT、Docker 的 DNAT 路径、IPv6 可达性必须独立核实。
- 已建立/相关 conntrack 流量会在本项目链中返回，不会被此规则立即终止；验证新连接时必须建立全新连接。
- 地址库更新失败时不应清空运行中的白名单；请查看 `journalctl -t cn-guard`、`systemctl status cn-guard-update.service` 和 `cn-guard status`。
- 不要手动执行 `iptables -F`、`nft flush ruleset`，也不要删除 Docker、RealmPanel、`YJ-FIREWALL-INPUT` 或其他已有表/链。
- 本项目仍需在目标 VPS 上做完整集成测试；仓库发布不代表已在用户生产环境验证。

## 数据来源

- IPv4: https://www.ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone
- IPv6: https://www.ipdeny.com/ipv6/ipaddresses/aggregated/cn-aggregated.zone

地址库内容由 IPdeny 提供；项目脚本会在运行时下载，不将第三方地址列表直接打包进仓库。
