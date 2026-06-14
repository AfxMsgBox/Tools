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

