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
