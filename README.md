# Tools

Personal tools workspace.

## URL 速度测试脚本（Debian）

使用 `curl` 测试 URL 在多次请求下的耗时与速度平均值。

```bash
./url_speed_test.sh "https://example.com" 5
```

参数：
- 第一个参数：URL
- 第二个参数：测试次数（正整数）

输出包含：
- 每次请求的 HTTP 状态与关键耗时
- 成功/HTTP 异常/curl 失败统计
- 各阶段平均耗时（DNS、TCP、TLS、TTFB、总耗时）与平均下载速度

## Git 子目录下载脚本

使用 `git-pull.sh` 将指定 Git 仓库某个分支中的项目子目录（包含其所有子目录和文件）下载到本地目录。

```bash
./git-pull.sh <git地址> <分支名> <项目子目录> [本地目录]
```

参数：
- 第一个参数：Git 仓库地址
- 第二个参数：分支名
- 第三个参数：仓库中的项目子目录
- 第四个参数：本地目录（可选，默认当前目录）

示例：

```bash
./git-pull.sh https://github.com/user/repo.git main scripts/tools ./tools
```


## RouterOS 静态租约名称同步到 UniFi Cloud Key

`sync_unifi_names.sh` 用于把 MikroTik RouterOS DHCP 静态租约里的中文注释同步到 UniFi Cloud Key 的客户端名称里。

同步规则固定为：

- 只读取 RouterOS DHCP lease 中 `dynamic=false` 的静态租约。
- 只同步有 `comment` 的租约。
- 只使用 `mac-address` 和 `comment`。
- 只更新 UniFi 已经存在或已经记录过的客户端。
- UniFi 当前找不到的 MAC 会跳过，后续设备上线并被 UniFi 记录后，定期同步会再处理。
- 不创建 UniFi client。
- 不修改 RouterOS。
- 不同步 IP 地址。
- 不保存密码。

### 依赖

Debian 下安装：

```bash
sudo apt-get update
sudo apt-get install curl jq
```

脚本不依赖 Python，也不依赖第三方语言库，直接用 `curl` 调用 RouterOS REST API 和 UniFi OS API，用 `jq` 处理 JSON。

### 前提

RouterOS 需要支持 REST API，通常要求 RouterOS v7，并启用 `www` 或 `www-ssl` 服务。建议使用 HTTPS：

```routeros
/ip service enable www-ssl
```

UniFi 侧按 Cloud Key Gen2 / UniFi OS 路径调用：

```text
https://<cloudkey>/api/auth/login
https://<cloudkey>/proxy/network/api/s/<site>/...
```

### 交互运行

直接运行：

```bash
./sync_unifi_names.sh
```

如果没有同时提供三个命令行参数，脚本会进入交互模式：

1. 从默认配置文件读取默认值。
2. 一步步提示输入 RouterOS 和 UniFi 参数。
3. 密码现场输入，不保存。
4. 保存非密码配置到配置文件。
5. 读取 RouterOS 和 UniFi 数据。
6. 显示预览。
7. 最后用 `是否执行同步? [y/N]:` 确认是否写入 UniFi。

默认配置文件是脚本同目录下的：

```text
unifi_routeros_sync.conf
```

配置文件不是 JSON，而是简单的字符串对，一行一个键值，格式为 `键 值`。配置文件示例：

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

脚本只支持三个参数：

- `--config`
- `--routeros-password`
- `--unifi-password`

只有三个参数同时指定时，才会进入静默模式，适合定时任务：

```bash
./sync_unifi_names.sh \
  --config /opt/routeros-unifi/unifi_routeros_sync.conf \
  --routeros-password 'RouterOS密码' \
  --unifi-password 'UniFi密码'
```

静默模式不会交互、不会询问确认，会直接同步并输出汇总结果。

### 输出和日志

脚本会按步骤输出当前进度，并在支持颜色的终端里使用彩色状态标记：

- 连接 RouterOS：显示是否连接成功，以及读取到多少条静态且带注释的 lease。
- 连接 Cloud Key：显示登录是否成功，以及读取到多少个 UniFi active/known clients。
- 生成同步计划：显示准备更新、名称已一致、UniFi 暂未找到的数量。
- 导入到 Cloud Key：每一条更新都会输出 MAC、名称和结果，例如：

```text
  11:33:33:55:66:77  电视机                          ...... success
```

如果连接、登录、读取或写入失败，脚本会输出失败原因，方便检查地址、端口、协议、账号密码、SSL 设置或 UniFi site 名称。

例如如果看到：

```text
curl: (7) Failed to connect to 10.68.20.2 port 443 ... Could not connect to server
```

这表示 Debian 机器无法和 Cloud Key 的 `IP:端口` 建立 TCP 连接，通常不是密码错误。建议先在同一台机器上测试：

```bash
curl -kI https://10.68.20.2:443/
```

如果这里也连不上，请优先检查 Cloud Key IP、端口、VLAN/防火墙、Cloud Key 是否开机，以及浏览器实际访问 Cloud Key Web 管理页面时使用的地址和端口。

### 返回码

- `0`：同步完成，没有客户端更新失败。
- `1`：依赖缺失、配置错误、登录失败或读取 API 失败。
- `2`：部分 UniFi 客户端更新失败。
