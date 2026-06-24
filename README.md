# Tools

常用 Shell 工具脚本。

依赖：`sudo apt-get install curl jq git`

## git-pull.sh

只下载 Git 仓库指定分支中的某个子目录到本地（浅克隆 + sparse-checkout）。

用法：

```bash
./git-pull.sh <git地址> <分支名> <项目子目录> [本地目录]
```

| 参数 | 说明 |
| ---- | ---- |
| `<git地址>` | 仓库地址，HTTPS 或 SSH。 |
| `<分支名>` | 分支名，例如 `main`。 |
| `<项目子目录>` | 仓库内相对路径，不能是绝对路径或含 `..`。 |
| `[本地目录]` | 可选，默认当前目录，不存在会自动创建。 |

示例：

```bash
./git-pull.sh https://github.com/user/repo.git main scripts/tools ./tools
```

退出码：`1` 参数错误 / 缺少 git / 子目录不存在。

## url_speed_test.sh

对同一 URL 连续请求 N 次，输出每次的 DNS/TCP/TLS/TTFB/总耗时和下载/上传速度，最后给出成功请求的平均值。

用法：

```bash
./url_speed_test.sh <URL> <次数>
```

| 参数 | 说明 |
| ---- | ---- |
| `<URL>` | 要测试的完整 URL。 |
| `<次数>` | 正整数。 |

示例：

```bash
./url_speed_test.sh "https://example.com" 5
```

退出码：`1` 参数错误或缺少 curl；`2` 全部请求失败，无法计算均值。

## sync_unifi_names.sh

把 RouterOS DHCP 静态租约的 `comment` 同步为 UniFi Cloud Key 中对应 MAC 客户端的名称。只更新 UniFi 已存在的客户端，不创建、不同步 IP、不修改 RouterOS。

用法：

```bash
./sync_unifi_names.sh [--config PATH] [--routeros-password PWD] [--unifi-password PWD]
```

| 参数 | 说明 |
| ---- | ---- |
| `--config` | 配置文件路径，默认 `./unifi_routeros_sync.conf`。 |
| `--routeros-password` | RouterOS 密码。 |
| `--unifi-password` | UniFi 密码。 |

模式：同时提供 `--config` 与两个密码（命令行或配置文件中）即静默执行；否则进入交互模式，会逐项询问并在写入前确认 `是否执行同步? [y/N]`。

配置文件字段（每行 `键 值`）：

| 字段 | 默认值 | 说明 |
| ---- | ------ | ---- |
| `RouterOSIP` | `192.168.88.1` | RouterOS 地址。 |
| `RouterOSPort` | `443` | REST API 端口。 |
| `RouterOSScheme` | `https` | `http` 或 `https`。 |
| `RouterOSUser` | `admin` | 用户名。 |
| `RouterOSPassword` | 空 | 可选，建议 `chmod 600`。 |
| `CloudKeyIP` | `192.168.88.2` | Cloud Key 地址。 |
| `CloudKeyPort` | `443` | HTTPS 端口。 |
| `UniFiUser` | `admin` | 用户名。 |
| `UniFiPassword` | 空 | 可选。 |
| `UniFiSite` | `default` | site key。 |
| `UniFiVerifySSL` | `false` | `false` 时跳过证书校验。 |

前提：RouterOS v7 启用 REST API（`/ip service enable www-ssl`），UniFi 账号具备 Network 客户端写入权限。

示例：

```bash
./sync_unifi_names.sh --config ./unifi_routeros_sync.conf \
  --routeros-password 'xxx' --unifi-password 'yyy'
```

退出码：`1` 依赖缺失 / 配置错误 / 登录或 API 失败；`2` 部分客户端更新失败。
