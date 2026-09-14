# username/memcached

用 MoonBit 实现的 **memcached 文本协议（text protocol）客户端库**。

它只负责两件事：把命令编码成 memcached 能读懂的字节，把服务器返回的字节解码成结构化数据。
传输通道被抽象成一个 `Connection` trait，因此整个包不依赖任何 socket，可以在没有 memcached
服务端的环境下完整地编码、解码与测试。

- 模块名：`username/memcached`，版本 `0.1.0`
- 首选编译目标：`wasm-gc`
- 依赖：仅 `moonbitlang/core` 的 `buffer`、`debug`、`encoding/utf8`、`string`

## 一、目录结构

| 路径 | 作用 |
| --- | --- |
| `memcached.mbt` | 协议编解码层：请求编码、响应解码、错误类型 |
| `transport.mbt` | 传输层抽象：`Connection` trait 与内存版 `ScriptedConnection` |
| `client.mbt` | 客户端层：`Client`、请求校验、便捷命令方法 |
| `memcached_test.mbt` | 黑盒测试（只使用公开 API） |
| `memcached_wbtest.mbt` | 白盒测试占位文件 |
| `cmd/main/main.mbt` | 可运行的演示程序（`moon run cmd/main`） |
| `moon.mod` / `moon.pkg` | 模块与包的元数据、依赖声明 |

## 二、分层架构

代码分为三层，依赖方向自上而下，每层都可以独立验证：

```text
        ┌─────────────────────────────────────────┐
        │  client.mbt   Client / 校验 / 便捷方法   │  面向使用者的 API
        └───────────────┬─────────────┬───────────┘
                        │             │
        ┌───────────────▼──┐   ┌──────▼──────────────┐
        │ memcached.mbt    │   │ transport.mbt       │
        │ Request::to_bytes│   │ trait Connection    │
        │ Decoder          │   │ ScriptedConnection  │
        │ 协议错误类型      │   │ TransportError      │
        └──────────────────┘   └─────────────────────┘
```

- **编解码层**（`memcached.mbt`）不持有任何连接，纯粹是字节进、字节出，所以可以脱离网络做单元测试。
- **传输层**（`transport.mbt`）只描述“字节怎么进出”，不关心 memcached 语义。
- **客户端层**（`client.mbt`）把两者串起来：写入编码后的请求，循环读取直到解出一个完整响应。

## 三、数据模型

### 请求

`Request` 是一个封闭枚举，覆盖文本协议里本库支持的全部命令：

| 变体 | 生成的一行命令 |
| --- | --- |
| `Storage(op, key, flags, exptime, value, cas)` | `<op> <key> <flags> <exptime> <bytes> [<cas>]\r\n<data>\r\n` |
| `Get(keys, with_cas)` | `get <key>...` 或 `gets <key>...` |
| `Delete(key)` | `delete <key>` |
| `Incr(key, delta)` | `incr <key> <delta>` |
| `Decr(key, delta)` | `decr <key> <delta>` |
| `Quit` | `quit` |

`StorageOp` 有 `Set / Add / Replace / Append / Prepend / Cas` 六种，只用于 `Storage` 变体，
其命令行首词由内部的 `StorageOp::name` 映射（`cas` 需要额外的 CAS 令牌）。

### 响应

| 类型 | 含义 |
| --- | --- |
| `Response::Values(Array[RetrievedValue])` | `get`/`gets` 的结果，可能为空（未命中） |
| `Response::Status(Status)` | 存储类命令与 `delete` 的终止状态行 |
| `Response::Counter(UInt64)` | `incr`/`decr` 执行后计数器的值 |
| `Status` | `Stored / NotStored / Exists / NotFound / Deleted / Touched` |
| `RetrievedValue` | 一个 `VALUE` 块：`key`、`flags`、`data`（字节）、`cas`（仅 `gets` 有值） |

### 错误

| 错误类型 | 变体 | 触发场景 |
| --- | --- | --- |
| `ProtocolError` | `Remote(RemoteErrorKind, String)` | 服务器回了 `ERROR` / `CLIENT_ERROR` / `SERVER_ERROR` |
| `ProtocolError` | `Malformed(String)` | 收到的字节不符合文本协议，或本地请求不合法 |
| `TransportError` | `Io(String)` | 底层通道失败，例如响应读一半连接被关闭 |

`RemoteErrorKind` 把服务器错误分成 `Generic / Client / Server` 三档，便于调用方区分
“命令不认得”“参数写错了”“服务器内部出错”。

## 四、请求编码流程

入口：`Request::to_bytes`（[memcached.mbt](memcached.mbt)）。

1. 新建一个 `@buffer.Buffer`。
2. 按 `Request` 变体分支拼装：
   - `Storage`：写命令词 → 空格 → key → `" <flags> <exptime> <bytes>"` →
     若有 CAS 令牌再补 `" <cas>"` → `\r\n` → 原始数据 → `\r\n`。
     其中 `<bytes>` 由 `value.length()` 现场计算，不需要调用方手工填写，避免长度与实际数据不一致。
   - `Get`：按 `with_cas` 选择 `get` 或 `gets`，然后依次追加每个 key。
   - `Delete / Incr / Decr / Quit`：直接按模板拼接。
3. `Buffer::to_bytes()` 返回最终字节。

编码结果示例：

```text
set foo 7 60 3\r\nbar\r\n          # Storage(Set, "foo", 7, 60, b"bar", None)
cas foo 0 0 3 42\r\nbar\r\n        # Storage(Cas, "foo", 0, 0, b"bar", Some(42))
get foo bar\r\n                    # Get(["foo","bar"], with_cas=false)
gets foo bar\r\n                   # Get(["foo","bar"], with_cas=true)
delete foo\r\n
incr counter 3\r\n
quit\r\n
```

注意：`to_bytes` 只描述“在线上长什么样”，**不做任何合法性校验**；校验发生在客户端层
（见第七节），这样编解码层保持成纯粹的函数。

## 五、响应解码流程

解码是从一个可增量填充的缓冲区里“拉”出完整响应。整体是一条三级流水线：

```text
Decoder::next
  └─ decode_response          在一段缓冲里找第一个 \r\n，定位首行
       ├─ "VALUE ..."  ──► parse_value_header ──► decode_value_blocks（递归）
       ├─ "END"        ──► Values([])       （get 全部未命中）
       └─ 其它         ──► decode_status    （状态行 / 错误行 / 计数器数字）
```

### 1. 定位首行

`decode_response` 先用 `find_crlf` 找到首个 `\r\n`。找不到就说明还只是响应的一部分，
返回 `None`，等调用方继续喂数据。找到后把首行按 UTF-8 解码成字符串，再按前缀分派。

首行按 UTF-8 解码而不是 `BytesView::to_string`，因为 key 允许非 ASCII；后者会得到
`Bytes` 的 `b"..."` 展示形式而不是文本。

### 2. 状态行 / 错误行 / 计数器

`decode_status` 用一串精确匹配把终止行映射成 `Status`：

- `STORED`、`NOT_STORED`、`EXISTS`、`NOT_FOUND`、`DELETED`、`TOUCHED` → 对应的 `Status`
- `ERROR` → `Remote(Generic, 行内容)`
- 以 `CLIENT_ERROR` 开头 → `Remote(Client, ...)`
- 以 `SERVER_ERROR` 开头 → `Remote(Server, ...)`
- 全为 ASCII 数字 → `Counter(值)`（`incr`/`decr` 的返回）
- 其它 → `Malformed("unexpected response line ...")`

### 3. `VALUE` 块

`parse_value_header` 把 `VALUE <key> <flags> <bytes> [<cas>]` 按空格拆成 4 或 5 个字段
（字段数不对直接算 `Malformed`），并用 `parse_decimal_int` / `parse_decimal` 做数字解析
（空串、非数字、超过 `i32` 上界都会被拒绝）。

`decode_value_blocks` 负责把数据主体和结尾的 `END` 收齐，关键点有两个：

- **数据块以字节数定帧，而不是以 `\r\n` 定帧。** 它先检查缓冲区是否已有
  `header.size` 个字节加尾随的 `\r\n`；不够就返回 `None` 等更多数据，够了就按声明长度切出
  `data`。因此值里含 `\r\n`（二进制数据）也不会被截断。若数据后面的两个字节不是 `\r\n`，
  报 `Malformed`。
- **递归收块。** 一个 `VALUE` 块处理完后，继续看下一行：是 `END` 就返回累积的
  `Values(values)`，是下一个 `VALUE` 就递归处理，其它内容报 `Malformed`。

返回值统一是 `(Response, 消耗字节数)` 或 `None`，其中“消耗字节数”让上层可以精确地从缓冲区
丢弃已消费的部分。

### 4. 增量解码器

`Decoder` 就是把“缓冲 + 解析”包起来的小状态机：

| 方法 | 语义 |
| --- | --- |
| `Decoder::new()` | 空缓冲区 |
| `Decoder::feed(view)` | 把新收到的字节追加到缓冲区尾部 |
| `Decoder::buffered()` | 尚未消费的字节数 |
| `Decoder::next()` | 尝试解出**一个**完整响应；不足一个响应时返回 `None`；成功时把已消费字节从缓冲区头部移除 |

这带来两个重要性质，测试里都有覆盖：

- **一次 read 可能只给半个响应** → `next()` 返回 `None`，`feed` 剩余部分后即可解出（响应跨包重组）。
- **一次 read 可能给多个响应** → 连续调用 `next()` 就能逐个取出（为流水线预留了能力）。

## 六、客户端执行流程

`Client` 持有**一个**被借用的连接和一个 `Decoder`：

```text
Client { conn : &Connection, decoder : Decoder }
```

### 核心：`Client::execute`

所有命令最终都汇到这一个函数，步骤固定为：

1. `validate_request(request)` —— 先做本地校验，不合法就抛 `Malformed`，**一个字节都不写出去**。
2. `conn.write(request.to_bytes())` —— 把编码后的请求整段写出。
3. 循环尝试解码：
   - `decoder.next()` 返回 `Some(response)` → 直接返回；
   - 返回 `None` → `conn.read(4096)` 再读一块；
     - 读到 0 字节说明对端已关闭 → 抛 `TransportError::Io("server closed the connection mid-response")`；
     - 否则 `decoder.feed(chunk)` 后继续循环。

这个“写一个、读一个”的串行模型让请求与响应的配对关系一目了然；`Decoder` 本身已经支持
一次读入多个响应，因此后续要改成流水线并不需要动解码代码。

### 便捷方法

`execute` 之上的薄封装，负责把 `Response` 转成具体类型，并检查响应种类是否符合预期
（`expect_values` / `expect_status` / `expect_counter`，种类不符即 `Malformed`）：

| 方法 | 命令 | 返回值 |
| --- | --- | --- |
| `store(op, key, value, flags, exptime, cas)` | 任意存储命令（可指定 flags / 过期时间 / CAS） | `Status` |
| `set` / `add` / `replace` / `append` / `prepend` | 对应存储命令，`flags=0, exptime=0, cas=None` | `Status` |
| `cas(key, value, cas)` | `cas`，带上期望令牌 | `Status` |
| `get(keys)` / `gets(keys)` | `get` / `gets` | `Array[RetrievedValue]` |
| `delete(key)` | `delete` | `Status` |
| `incr(key, delta)` / `decr(key, delta)` | `incr` / `decr` | `UInt64`（执行后的值） |
| `quit()` | `quit` | `Unit` |

`quit` 的语义单独说明：服务器对 `quit` **不回复**，所以这里只写不读；连接用
`errdefer self.conn.close()` 保护，即使写失败也会关闭，避免连接泄漏，随后再把写错误抛出去。

## 七、请求校验

校验发生在 `client.mbt`，目的是拦住文本协议无法表达、或会让服务器解析错位的请求。

### key 的合法性（`is_valid_key` / `validate_key`）

1. 非空，且 UTF-8 编码后长度不超过 `MAX_KEY_LENGTH = 250` 字节（服务器按字节计数，不是字符数）；
2. 每个字节的值不能 `<= 0x20`（含空格、制表符、换行等空白与控制字符），也不能是 `0x7F`。

原因是服务器用空格切分命令行，key 里出现空格会导致字段错位；`gets` 解码也依赖 key 不含
控制字符。多字节 UTF-8 的后续字节都 `>= 0x80`，因此正常的中文等非 ASCII key 可以通过。

### 请求级校验（`validate_request`）

- `Storage` / `Delete` / `Incr` / `Decr`：校验 key；
- `Get`：key 列表至少一个（否则生成 `get \r\n` 毫无意义），并逐个校验 key；
- `Quit`：无需校验。

## 八、传输层与测试替身

`Connection` 是一个开放 trait，只有三个方法：

```text
trait Connection {
  fn write(Self, BytesView) -> Unit raise TransportError
  fn read(Self, Int) -> Bytes raise TransportError   // 空结果 = 对端已关闭
  fn close(Self) -> Unit raise TransportError
}
```

`ScriptedConnection` 是它的内存实现，用于示例和测试：

- 构造时给一串 `chunks`，`read` **每次只回放一个 chunk**，并截断到请求的字节数；
  剩余部分留到下一次 `read`。这让测试可以精确地制造“响应被拆成多段”的场景。
- `write` 把客户端写出的所有字节累积进内部 `Buffer`，通过 `written()` 取回，因此它同时是一个 spy，
  可以逐字节断言线上内容。
- chunk 用尽后 `read` 返回空字节，客户端据此判定为连接关闭。
- `close` 丢弃剩余的 chunk 和待读数据。

## 九、测试与示例

### 黑盒测试（`memcached_test.mbt`）

全部通过公开 API 驱动，不需要 memcached 服务端，覆盖：

- **编码**：存储命令行与数据块、CAS 令牌、空值、get/gets 多 key、delete/incr/decr/quit；
- **解码**：六种状态行、计数器数字、单个/多个 `VALUE` 块、未命中（`END`）、
  数据块以字节数定帧（值内含 `\r\n`）、响应跨 feed 重组、单次 feed 多响应、
  服务器错误的三种类别、非法帧（未知行、字段数不对、数据块未以 CRLF 结尾）；
- **客户端**：单连接上 set + get 的完整往返与线上字节断言、cas 透传令牌、计数器返回值、
  `quit`、响应中途断连报 `TransportError::Io`、未知行报 `Malformed`、
  key 长度与字符合法性边界（250 通过 / 251 拒绝 / 空串 / 空格 / 制表符 / 换行）、
  空 key 列表在写出任何字节之前就被拒绝、声明的字节数远大于可用数据时只是等待而不是错误分帧。

### 运行方式

```shell
moon test          # 跑测试
moon run cmd/main  # 跑演示程序
moon info && moon fmt
```

`cmd/main/main.mbt` 用 `ScriptedConnection` 演示三段内容：请求编码结果（带转义，便于看清
`\r\n` 分帧）、单连接客户端的 set/get 往返与线上字节、增量解码器“半个响应等待、补齐后解出”。

## 十、边界与已知限制

- **未实现流水线**：`execute` 一次只发一个请求、等一个响应。多发多收需要新的批处理 API
  （解码器已具备该能力）。
- **便捷方法不透传 flags/exptime**：`set`/`add`/`replace`/`append`/`prepend`/`cas` 固定
  `flags=0, exptime=0`；需要其它取值请直接用 `store`。
- **未覆盖的命令**：`touch`、`noreply`、`version`、`stats`、`flush_all`、二进制协议等均未实现。
- **校验范围仅限 key**：`flags`、`exptime`、`cas` 的取值未做范围检查，`exptime` 为负会直接
  编码成 `-1` 交给服务器裁决；长度只用 `Int` 表达，超大值会受到 `i32` 上界约束。
- **解码递归深度等于 `VALUE` 块数**：`decode_value_blocks` 是递归实现，一次 `get` 大量 key
  时会按块数加深调用栈，极端情况下存在栈溢出风险。
- **等待策略没有上限**：当声明的字节数或响应尚未收齐时，`Decoder::next` 只返回 `None` 等待更多
  数据，客户端会一直读到对端关闭为止；缓冲区会随之增长，没有“单个响应上限”或超时保护。
- **计数器命令对非数字值**：memcached 会回 `CLIENT_ERROR cannot increment or decrement
  non-numeric value`，在本库中表现为 `ProtocolError::Remote(Client, ...)`。
- **`quit` 不读响应**：这是协议约定（服务器不回复）；若调用方在 `quit` 之后继续用同一
  `Client`，行为未定义。
- **`ScriptedConnection` 仅用于测试**：它不回放完就返回空字节，真实实现（socket 等）需要自行
  实现 `Connection` 并遵守同样的约定——空结果表示对端关闭。

## 十一、扩展示例：新增一条命令

以增加 `touch <key> <exptime>` 为例，改动点固定为四处：

1. `Request` 增加变体（含 `key`、`exptime`）；
2. `Request::to_bytes` 增加对应分支；
3. `client.mbt` 的 `validate_request` 增加 key 校验分支（保持穷尽匹配）；
4. `Client` 增加便捷方法，并用 `expect_status` 收尾。

若要接真实网络，只需给 socket 实现 `Connection`：`read` 在无数据时阻塞，返回空表示对端关闭，
其余逻辑无需改动。

帝弓啊，请你垂眸
