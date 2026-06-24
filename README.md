# Tools

几个常用 Shell 工具脚本。

## 依赖

```bash
sudo apt-get update
sudo apt-get install curl jq git
```

## url_speed_test.sh

测试一个 URL 多次请求的耗时和速度。

```bash
./url_speed_test.sh <URL> <次数>
```

示例：

```bash
./url_speed_test.sh "https://example.com" 5
```

会输出每次请求的 HTTP 状态、DNS/TCP/TLS/TTFB/总耗时、下载/上传速度，以及成功请求的平均值。

## git-pull.sh

只下载远程 Git 仓库里的某个子目录到本地。

```bash
./git-pull.sh <git地址> <分支名> <项目子目录> [本地目录]
```

示例：

```bash
./git-pull.sh https://github.com/user/repo.git main scripts/tools ./tools
```

说明：

- `[本地目录]` 可省略，默认当前目录。
- `<项目子目录>` 必须是仓库内相对路径，不能是绝对路径，也不能包含 `..`。

## sync_unifi_names.sh

把 RouterOS DHCP 静态租约的 `comment` 同步到 UniFi Cloud Key 客户端名称。

规则：

- 只读取 RouterOS 中 `dynamic=false` 且有 `comment` 的 DHCP lease。
- 只更新 UniFi 已存在/已记录过的客户端，不创建新客户端。
- 不修改 RouterOS，不同步 IP，不保存密码。

### RouterOS 前提

RouterOS 需支持 REST API，通常要求 RouterOS v7，并启用 `www` 或 `www-ssl` 服务，例如：

```routeros
/ip service enable www-ssl
```

### 交互运行

```bash
./sync_unifi_names.sh
```

脚本会提示输入 RouterOS / UniFi 地址、账号、密码和 site，保存非密码配置，预览同步计划，最后询问是否执行。

默认配置文件：

```text
./unifi_routeros_sync.conf
```

配置示例：

```text
RouterOSIP 192.168.88.1
RouterOSPort 443
RouterOSScheme https
RouterOSUser admin
CloudKeyIP 192.168.88.2
CloudKeyPort 443
UniFiUser admin
UniFiSite default
UniFiVerifySSL false
```

### 静默运行 / 定时任务

三个参数必须同时提供，才会进入静默模式：

```bash
./sync_unifi_names.sh \
  --config /opt/routeros-unifi/unifi_routeros_sync.conf \
  --routeros-password 'RouterOS密码' \
  --unifi-password 'UniFi密码'
```

### 返回码

- `0`：同步完成，没有客户端更新失败。
- `1`：依赖缺失、配置错误、登录失败或读取 API 失败。
- `2`：部分 UniFi 客户端更新失败。
