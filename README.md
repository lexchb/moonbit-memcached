# lexchb/memcached

[![CI](https://github.com/lexchb/moonbit-memcached/actions/workflows/ci.yml/badge.svg)](https://github.com/lexchb/moonbit-memcached/actions/workflows/ci.yml)

用 MoonBit 实现的 **memcached 文本协议（text protocol）客户端库**。

它只负责两件事：把命令编码成 memcached 能读懂的字节，把服务器返回的字节解码成结构化数据。
传输通道被抽象成一个 `Connection` trait，因此整个包不依赖任何 socket，可以在没有 memcached
服务端的环境下完整地编码、解码与测试。

- 模块名：`lexchb/memcached`，版本 `0.1.0`
- 首选编译目标：`wasm-gc`
- 依赖：仅 `moonbitlang/core` 的 `buffer`、`debug`、`encoding/utf8`、`string`

## 安装

```shell
moon add lexchb/memcached
```

本包不引入任何第三方依赖，因此在没有 memcached 服务端、也没有网络的环境里同样可以构建、
测试与运行示例。

## 快速开始

传输通道由使用方实现 `Connection`；包内自带的内存实现 `ScriptedConnection` 让下面的最小
样例不需要 socket 就能跑通：

```moonbit
// 内存转录：服务器依次回答 STORED 与一个 VALUE 块。
let conn = @memcached.ScriptedConnection::new([
  b"STORED\r\n",
  b"VALUE foo 0 3\r\nbar\r\nEND\r\n",
])
let client = @memcached.Client::new(conn)
println(client.set("foo", b"bar")) // Status::Stored
for value in client.get(["foo"]) {
  println(value.key) // foo
  println(value.data) // b"bar"
}
```

接真实网络时只需为 socket 实现同一个 `Connection`（`read` 在无数据时阻塞，返回空表示对端
已关闭），上面这段客户端代码不需要任何改动；超时、重连与连接池同样落在实现里。

仓库内自带一个可运行的演示程序，覆盖编码结果、单连接往返、管理命令、流水线与增量解码：

```shell
moon run cmd/main
```

## 支持的命令

`set` / `add` / `replace` / `append` / `prepend` / `cas`、`get` / `gets`、`gat` / `gats`、
`delete`、`incr` / `decr`、`touch`、`version`、`stats [<section>]`、`flush_all`、`verbosity`、
`cache_memlimit`、`slabs reassign` / `slabs automove`、`quit`；其中存储类命令、`delete`、
`incr` / `decr`、`touch`、`flush_all`、`verbosity`、`cache_memlimit` 与 `slabs` 系命令支持
`noreply`。另提供流水线批处理（`Client::pipeline`）与失步恢复（`Client::resync`）。

## 项目结构

| 路径 | 作用 |
| --- | --- |
| `memcached.mbt` | 协议编解码层：请求编码、响应解码、错误类型 |
| `transport.mbt` | 传输层抽象：`Connection` trait 与内存版 `ScriptedConnection` |
| `client.mbt` | 客户端层：`Client`、请求校验、便捷命令方法 |
| `memcached_test.mbt` | 黑盒测试（只使用公开 API） |
| `memcached_wbtest.mbt` | 白盒测试：直接验证私有编解码与校验函数 |
| `cmd/main/main.mbt` | 可运行的演示程序（`moon run cmd/main`） |
| `README.mbt.md` | 完整设计文档：数据模型、编解码流程、校验规则、边界与限制 |

## 开发与测试

```shell
moon check     # 类型检查
moon build     # 构建模块
moon test      # 跑测试
moon run cmd/main
```

CI（`.github/workflows/ci.yml`）在每次 push 与 pull request 上依次执行 `moon check`、
`moon fmt --check`、`moon build`、`moon test`。

## 许可证

本项目采用 Apache-2.0 许可证，全文见 [LICENSE](LICENSE)。