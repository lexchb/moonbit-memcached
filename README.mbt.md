# lexchb/memcached

用 MoonBit 实现的 **memcached 文本协议（text protocol）客户端库**。

它只负责两件事：把命令编码成 memcached 能读懂的字节，把服务器返回的字节解码成结构化数据。
传输通道被抽象成一个 `Connection` trait，因此整个包不依赖任何 socket，可以在没有 memcached
服务端的环境下完整地编码、解码与测试。

- 模块名：`lexchb/memcached`，版本 `0.1.0`
- 首选编译目标：`wasm-gc`
- 依赖：仅 `moonbitlang/core` 的 `buffer`、`debug`、`encoding/utf8`、`string`

## 一、目录结构

| 路径 | 作用 |
| --- | --- |
| `memcached.mbt` | 协议编解码层：请求编码、响应解码、错误类型 |
| `transport.mbt` | 传输层抽象：`Connection` trait 与内存版 `ScriptedConnection` |
| `client.mbt` | 客户端层：`Client`、请求校验、便捷命令方法 |
| `memcached_test.mbt` | 黑盒测试（只使用公开 API） |
| `memcached_wbtest.mbt` | 白盒测试：直接验证私有编解码与校验函数 |
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
| `Storage(op, key, flags, exptime, value, cas, noreply)` | `<op> <key> <flags> <exptime> <bytes> [<cas>] [noreply]\r\n<data>\r\n` |
| `Get(keys, with_cas)` | `get <key>...` 或 `gets <key>...` |
| `Gat(keys, exptime, with_cas)` | `gat <exptime> <key>...` 或 `gats <exptime> <key>...` |
| `Delete(key, noreply)` | `delete <key> [noreply]` |
| `Incr(key, delta, noreply)` | `incr <key> <delta> [noreply]` |
| `Decr(key, delta, noreply)` | `decr <key> <delta> [noreply]` |
| `Touch(key, exptime, noreply)` | `touch <key> <exptime> [noreply]` |
| `Version` | `version` |
| `Stats(sub)` | `stats` 或 `stats [<sub>]`（`<sub>` 可以是多个词，如 `detail on`） |
| `FlushAll(delay, noreply)` | `flush_all [<delay>] [noreply]` |
| `Verbosity(level, noreply)` | `verbosity <level> [noreply]` |
| `CacheMemlimit(megabytes, noreply)` | `cache_memlimit <megabytes> [noreply]` |
| `SlabsReassign(src, dst, noreply)` | `slabs reassign <src> <dst> [noreply]`（`src` 为 `-1` 时由服务器自选源 slab） |
| `SlabsAutomove(mode, noreply)` | `slabs automove <mode> [noreply]`（`mode` 为 `0` 关 / `1` 开 / `2` 激进） |
| `Quit` | `quit` |

`StorageOp` 有 `Set / Add / Replace / Append / Prepend / Cas` 六种，只用于 `Storage` 变体，
其命令行首词由内部的 `StorageOp::name` 映射（`cas` 需要额外的 CAS 令牌）。

### noreply 与「是否有应答」

`noreply` 是协议里的一个可选尾词：加上它，服务器执行完命令后**不发送**终止状态行。
这直接决定了调用方要不要读回响应，因此由 `Request::expects_reply` 统一裁决：

| 命令 | 是否有应答 |
| --- | --- |
| `Get` / `Gat` / `Version` / `Stats` | 恒为「有」 |
| `Storage` / `Delete` / `Incr` / `Decr` / `Touch` / `FlushAll` / `Verbosity` / `CacheMemlimit` / `SlabsReassign` / `SlabsAutomove` | 取 `noreply` 的相反数 |
| `Quit` | 恒为「无」（协议规定不回复） |

这条信息被客户端用来把两个方向分开：有应答的走 `execute`，无应答的走 `send`，
两者互相拒绝对方的请求（见第六节）。

### 响应

| 类型 | 含义 |
| --- | --- |
| `Response::Values(Array[RetrievedValue])` | `get`/`gets`/`gat`/`gats` 的结果，可能为空（未命中） |
| `Response::Status(Status)` | 存储类、`delete`、`touch`、`flush_all`、`verbosity`、`cache_memlimit`、`slabs` 的终止状态行 |
| `Response::Counter(UInt64)` | `incr`/`decr` 执行后计数器的值 |
| `Response::Version(String)` | `version` 的版本字符串 |
| `Response::Stats(Array[StatEntry])` | `stats` 的 `STAT` 行，直到 `END` |
| `Status` | `Stored / NotStored / Exists / NotFound / Deleted / Touched / Ok` |
| `RetrievedValue` | 一个 `VALUE` 块：`key`、`flags`、`data`（字节）、`cas`（仅 `gets`/`gats` 有值） |
| `StatEntry` | 一条 `STAT <name> <value>`：`name`、`value`（都是字符串） |

`StatEntry` 的 `value` 保持字符串形态，因为 memcached 既报数字也报自由文本
（`STAT version 1.6.21`）；`stats items` 这类分节把维度嵌进名字里（`items:1:number`），
而不是新增字段。

### 错误

| 错误类型 | 变体 | 触发场景 |
| --- | --- | --- |
| `ProtocolError` | `Remote(RemoteErrorKind, String)` | 服务器回了 `ERROR` / `CLIENT_ERROR` / `SERVER_ERROR` |
| `ProtocolError` | `Malformed(String)` | 收到的字节不符合文本协议，或本地请求不合法 |
| `ProtocolError` | `Desynchronised(Int, Int)` | 缓冲区超过上限仍未解出完整响应，流已失去分帧（两个字段依次是上限与已缓冲字节数） |
| `TransportError` | `Io(String)` | 底层通道失败，例如响应读一半连接被关闭 |

`RemoteErrorKind` 把服务器错误分成 `Generic / Client / Server` 三档，便于调用方区分
“命令不认得”“参数写错了”“服务器内部出错”。`Desynchronised` 与 `Malformed` 的区别在于
**责任方**：前者说明本地缓冲里留着一段永远补不全的残片，后者说明这段字节本身就不是合法响应。
`Malformed` 的消息里若引用了对端的原始字节，会先转义并截断再拼进去（见第五节第 6 小节）；
`Remote` 携带的则是服务器错误行的**原文**，不转义也不截断——它和 `STAT` 行的字段一样，
是要交给调用方使用的内容，而不是消息里的引用。

## 四、请求编码流程

入口：`Request::to_bytes`（[memcached.mbt](memcached.mbt)）。

1. 新建一个 `@buffer.Buffer`。
2. 按 `Request` 变体分支拼装：
   - `Storage`：写命令词 → 空格 → key → `" <flags> <exptime> <bytes>"` →
     若有 CAS 令牌再补 `" <cas>"` → 若有 `noreply` 再补 `" noreply"` → `\r\n` → 原始数据 → `\r\n`。
     其中 `<bytes>` 由 `value.length()` 现场计算，不需要调用方手工填写，避免长度与实际数据不一致。
   - `Get`：按 `with_cas` 选择 `get` 或 `gets`，然后依次追加每个 key。
   - `Gat`：先写 `gat`/`gats` 与 `<exptime>`，再追加每个 key——注意过期时间在 key **之前**。
   - `Delete / Incr / Decr / Touch`：按模板拼接，`noreply` 由 `write_noreply` 统一追加在行尾。
   - `Version`：常量 `version\r\n`。
   - `Stats`：写 `stats`，有分节名时再补 `" <sub>"`——段名按调用方给出的样子原样写出，
     因此 `detail on`、`cachedump 1 100` 这类带参数的段名会变成 `stats detail on` 这样的命令行。
   - `FlushAll`：写 `flush_all`，有延迟时再补 `" <delay>"`，最后是 `noreply`。
   - `Verbosity`：写 `verbosity <level>`，最后是 `noreply`。
   - `CacheMemlimit`：写 `cache_memlimit <megabytes>`，最后是 `noreply`。
   - `SlabsReassign`：写 `slabs reassign <src> <dst>`，最后是 `noreply`。
   - `SlabsAutomove`：写 `slabs automove <mode>`，最后是 `noreply`。
   - `Quit`：常量 `quit\r\n`。
3. `Buffer::to_bytes()` 返回最终字节。

因为 `noreply` 总是命令行最后一个词，`write_noreply` 这个小助手保证了它不会插到
`<delay>`、`<exptime>` 之类的参数前面。

编码结果示例：

```text
set foo 7 60 3\r\nbar\r\n          # Storage(Set, "foo", 7, 60, b"bar", None, false)
set foo 0 0 3 noreply\r\nbar\r\n   # Storage(Set, "foo", 0, 0, b"bar", None, true)
cas foo 0 0 3 42\r\nbar\r\n        # Storage(Cas, "foo", 0, 0, b"bar", Some(42), false)
get foo bar\r\n                    # Get(["foo","bar"], with_cas=false)
gets foo bar\r\n                   # Get(["foo","bar"], with_cas=true)
gat 30 foo bar\r\n                 # Gat(["foo","bar"], 30, with_cas=false)
touch foo 30\r\n                   # Touch("foo", 30, noreply=false)
delete foo\r\n
delete foo noreply\r\n
incr counter 3\r\n
version\r\n
stats items\r\n
flush_all\r\n                      # FlushAll(None, noreply=false)
flush_all 10\r\n                   # FlushAll(Some(10), noreply=false)
verbosity 2\r\n
cache_memlimit 64\r\n              # CacheMemlimit(64, noreply=false)
slabs reassign -1 2\r\n            # SlabsReassign(-1, 2, noreply=false)
slabs automove 2 noreply\r\n       # SlabsAutomove(2, noreply=true)
quit\r\n
```

注意：`to_bytes` 只描述“在线上长什么样”，**不做任何合法性校验**；校验发生在客户端层
（见第七节），这样编解码层保持成纯粹的函数。

## 五、响应解码流程

解码是从一个可增量填充的缓冲区里“拉”出完整响应。整体是一条三级流水线：

```text
Decoder::next
  └─ decode_response          在一段缓冲里找第一个 \r\n，定位首行
       ├─ "VALUE ..."  ──► parse_value_header ──► decode_value_blocks（循环）
       ├─ "STAT ..."   ──► parse_stat_line ────► decode_stats（循环）
       ├─ "VERSION ..." ─► Version(去掉 8 字节前缀后的文本)
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

- `STORED`、`NOT_STORED`、`EXISTS`、`NOT_FOUND`、`DELETED`、`TOUCHED`、`OK` → 对应的 `Status`
  （`OK` 是 `flush_all`、`verbosity`、`cache_memlimit` 与 `slabs` 系命令的应答）
- `ERROR` → `Remote(Generic, 行内容)`
- 以 `CLIENT_ERROR` 开头 → `Remote(Client, ...)`
- 以 `SERVER_ERROR` 开头 → `Remote(Server, ...)`
- 全为 ASCII 数字 → `Counter(值)`（`incr`/`decr` 的返回）
- 其它 → `Malformed("unexpected response line ...")`

### 3. `VALUE` 块

`parse_value_header` 把 `VALUE <key> <flags> <bytes> [<cas>]` 按空格拆成 4 或 5 个字段
（字段数不对直接算 `Malformed`），并用 `parse_decimal_int` / `parse_decimal` 做数字解析：
空串与非数字一律拒绝；`parse_decimal` 只受 **u64** 上界约束（cas 令牌用），`parse_decimal_int`
在其之上再限制到 **i32**（`flags`、`bytes` 两个字段用）。

`<bytes>` 另有一道上限，它**不是常数，而是接收方解码器的 `limit`**：`decode_response` 把这个
上限一路传给 `parse_value_header`。判据不是「块本身是否超过 `limit`」，而是**这个块连同它的分帧
能否装进 `limit`**：一个 `VALUE` 块必定与它的头行、块尾的 `\r\n` 和收尾的 `END` 行同处一个
缓冲区（常量 `VALUE_RETRIEVAL_FRAMING` 就是这段分帧本身——`b"\r\n\r\nEND\r\n"`，头行剥掉的
CRLF、块尾的 `\r\n`、收尾的 `END\r\n`——字节数由编译器数，不靠手算；名字落在「一次检索」而不是
「一个块」上，因为收尾的 `END` 属于承载各块的那次检索，它量的是「能装下一个块的最小应答」），
这些开销要先从 `limit` 里扣掉，剩下的才是数据能用的额度。因此头检查与 `next()` 的
`buffered <= limit` 是同一根尺子，不会留下「头放过了、缓冲却永远凑不齐」的空档；装不下的头
当场报 `Malformed`，而不是先缓冲到上限再说。多块响应下这道检查只是必要条件，例外见第五节。

消息里同时给出声明值、计入分帧后的实际需求与上限（`a VALUE block of 100 bytes needs 122 bytes
with its header and the END line, more than the 8-byte block limit`），因为「太大」有两种成因：
对端失了分帧，或者**调用方的 `limit` 比服务端的 item 上限还小**。默认上限 8 MiB 高于 memcached
默认的 1 MiB item 上限，所以默认配置下这条路径只在失步时触发；把 `limit` 调小之后，它同样会
拦下本来合法的块。

`decode_value_blocks` 负责把数据主体和结尾的 `END` 收齐，关键点有两个：

- **数据块以字节数定帧，而不是以 `\r\n` 定帧。** 它先检查缓冲区是否已有
  `header.size` 个字节加尾随的 `\r\n`；不够就返回 `None` 等更多数据，够了就按声明长度切出
  `data`。因此值里含 `\r\n`（二进制数据）也不会被截断。若数据后面的两个字节不是 `\r\n`，
  报 `Malformed`。
- **循环收块。** 一个 `VALUE` 块处理完后，继续看下一行：是 `END` 就返回累积的
  `Values(values)`，是下一个 `VALUE` 就换掉当前 header 接着处理，其它内容报 `Malformed`。
  这里刻意不用递归：一次 `get` 上百个 key 时，递归深度会等于块数。

返回值统一是 `(Response, 消耗字节数)` 或 `None`，其中“消耗字节数”让上层可以精确地从缓冲区
丢弃已消费的部分。

### 4. `STAT` 块与 `VERSION` 行

`stats` 的应答结构与 `get` 有一处要注意的区别：**它没有自己的首行**。`get` 的应答以
`VALUE ...` 这行头开始、以 `END` 结束；而 `stats` 的应答里每一行都是 `STAT`，
首行同样是统计数据。所以 `decode_response` 分派到 `decode_stats` 时是**从头**解码的，
而不是像 `decode_value_blocks` 那样跳过首行。

`parse_stat_line` 只按**第一个**空格切分 `STAT <name> <value>`，因为值里可能有空格
（`STAT libevent 2.1.12-stable`）。缺少空格或整行不是 `STAT` 前缀都报 `Malformed`。
第一个空格同时也是字段的分界，所以名字不能为空：`STAT  pid 1` 里那个空格正好开启了名字，
这一行没有名字可报，同样算 `Malformed`。

`VERSION <string>` 只需要截掉前缀。前缀 `"VERSION "` 是 8 个 ASCII 字节，所以它的字符长度
也等于字节长度，可以直接当作字节偏移使用；截取发生在原始字节上，再按 UTF-8 解码成文本。

### 5. 增量解码器

`Decoder` 就是把“缓冲 + 解析”包起来的小状态机：

| 方法 | 语义 |
| --- | --- |
| `Decoder::new()` | 空缓冲区，上限为 `DEFAULT_BUFFER_LIMIT`（8 MiB） |
| `Decoder::with_limit(limit)` | 空缓冲区，上限为 `limit` |
| `Decoder::limit()` | 这个解码器接受的上限字节数：既是缓冲区上限，也是它接受的 `VALUE` 块上限 |
| `Decoder::feed(view)` | 把新收到的字节追加到缓冲区尾部 |
| `Decoder::buffered()` | 尚未消费的字节数 |
| `Decoder::next()` | 尝试解出**一个**完整响应；不足一个响应时返回 `None`；成功时把已消费字节从缓冲区头部移除 |
| `Decoder::resync()` | 丢弃整个缓冲区，用于流已失去分帧后的重新开始 |

这带来两个重要性质，测试里都有覆盖：

- **一次 read 可能只给半个响应** → `next()` 返回 `None`，`feed` 剩余部分后即可解出（响应跨包重组）。
- **一次 read 可能给多个响应** → 连续调用 `next()` 就能逐个取出（为流水线预留了能力）。

### 缓冲上限与失步恢复

`next()` 返回 `None` 意味着“还在等剩下的字节”。但一个**永远补不全**的流会让缓冲区无限增长，
所以缓冲区长度超过 `limit` 时，`next()` 不再返回 `None`，而是抛
`Desynchronised(limit, buffered)`：此时留下的是一段永远解不出响应的残片，继续等下去只会耗尽内存。

默认上限 `DEFAULT_BUFFER_LIMIT = 8 MiB`：memcached 默认单条 item 最大 1 MiB，而一次多 key
检索会把每个命中的 `VALUE` 块拼在一起，8 MiB 给“几条满载 item”留了余量。需要更紧或更松的
约束时用 `Decoder::with_limit` / `Client::with_limit`。

同一个 `limit` 还有第二个作用：它就是**能被接受的 `VALUE` 块大小上限**。块必须整块缓冲才能
解码，所以一个连同分帧都放不进 `limit` 的头在这个解码器里永远凑不齐数据，属于当场报
`Malformed` 的情形（见第三节）；`Desynchronised` 则留给「块本身放得下、只是字节一直堆不完」的
流。二者是同一根尺子的两端：调大 `limit` 为更大的块让位，调小则同时收紧这两道闸。

头检查把开销算进去了，所以没有「头放过、随后才按 `Desynchronised` 报出」的空档：能凑齐的
最大块正是 `limit` 减去头行长度与 `VALUE_RETRIEVAL_FRAMING` 的字节数，判据与 `next()` 的
`buffered <= limit` 对齐。换句话说，一条声明若连自己的分帧都放不进缓冲区，它描述的不是一个
还在路上的块，而是一段已经失去分帧的流，当场说出来比白白缓冲到上限再报错要好。

一个例外是**多块响应**：头检查对每个头都用整份 `limit`，而不是「前面的块用剩多少」。于是它对整段
序列只是**必要条件**：每个块单独看都放得下、合起来却超过缓冲的响应不会被这里拦下。这也不算漏判，
因为 `limit` 约束的是**等待解码的字节**，不是「一个响应可以有多大」——整段一次到齐的响应照常解码，
只有「已经在缓冲里堆着、却还没收完」的响应才会被 `next()` 按 `Desynchronised` 报出。两道闸的分工
因此是「这个解码器永远分不出帧的响应」与「还等着收完、但缓冲已经装不下的响应」。

`resync()` 是配套的恢复动作：它清空缓冲区，让下一个响应从干净的状态开始。**只有确认流的
分帧已经重新开始时才该调用**（典型场景是重连之后）；在正常流上调用会丢掉尚未消费的字节。

### 6. 错误信息里的对端数据

解码失败的消息里经常会引用出错的那段原始字节（`unexpected response line '...'`、`data block
of key '...'`）。这些字节来自对端，直接拼进消息会有两个问题：控制字符会原样出现在日志里
（`\r` 能把一行消息撕成两行），而超长的一行会把真正的原因挤到看不见的地方。

所以 `Malformed` 消息里所有**嵌入对端数据**的位置都经过 `quote`：

- 逐字符调用 `Char::escape(quote=false)`：回车、换行、制表等控制字符被写成「反斜杠 + 字母」
  两个字符的形式，不可打印字符写成 `\u{7f}` 这样，因此消息始终是单行可读的；
- 最多引用 `MAX_QUOTED_CHARS = 64` 个字符，超出部分截断并补 `...`。

注意区分两类数据：`STAT` 行里的 `name` / `value` 与 `Remote` 携带的错误行是
**要交给调用方使用**的内容，原样保留；只有 `Malformed` 消息里的引用才做转义与截断。

## 六、客户端执行流程

`Client` 持有**一个**被借用的连接和一个 `Decoder`：

```text
Client { conn : &Connection, decoder : Decoder }
```

`Client::new` 用默认上限的 `Decoder`；`Client::with_limit(conn, limit)` 换一个缓冲上限不同的
解码器：超过 `limit` 字节仍未见完整响应时按失步处理，而 `VALUE` 头声明的块连同分帧都放不进
`limit` 时当场报 `Malformed`（见第五节「缓冲上限与失步恢复」）。

### 两个入口：`execute` 与 `send`

写请求的入口有两个，按“这条命令有没有应答”分工，守卫互为反面：

| 入口 | 接受的请求 | 行为 |
| --- | --- | --- |
| `execute(request)` | `expects_reply()` 为 `true` | 写出请求，读到**一整个**响应才返回 |
| `send(request)` | `expects_reply()` 为 `false`：`quit`，或带 `noreply` 的变更类命令 | 只写出请求，不读任何字节 |

两个方向都必须拦：把 `noreply` 命令交给 `execute`，它会一直读到对端关闭才报错；把有应答的
命令交给 `send`，那条应答会留在缓冲里被当成**下一条**命令的响应。所以 `execute` 对无应答的
请求抛 `Malformed("this command has no reply to read; use 'send' for it")`，`send` 对有应答的
请求抛 `Malformed("this command has a reply to read; use 'execute' for it")`。

`execute` 的步骤固定为：

1. `validate_request(request)` —— 先做本地校验，不合法就抛 `Malformed`，**一个字节都不写出去**；
2. `guard request.expects_reply()` —— 拦下没有应答可读的命令；
3. `conn.write(request.to_bytes())` —— 把编码后的请求整段写出；
4. 循环尝试解码：
   - `decoder.next()` 返回 `Some(response)` → 直接返回；
   - 返回 `None` → `conn.read(4096)` 再读一块；
     - 读到 0 字节说明对端已关闭 → 抛 `TransportError::Io("server closed the connection mid-response")`；
     - 否则 `decoder.feed(chunk)` 后继续循环。

这个“写一个、读一个”的串行模型让请求与响应的配对关系一目了然；`Decoder` 本身已经支持
一次读入多个响应，因此后续要改成流水线并不需要动解码代码。

### 便捷方法

`execute` 之上的薄封装，负责把 `Response` 转成具体类型，并检查响应种类是否符合预期
（`expect_values` / `expect_status` / `expect_counter` / `expect_version` / `expect_stats`，
种类不符即 `Malformed`）：

| 方法 | 命令 | 返回值 |
| --- | --- | --- |
| `store(op, key, value, flags, exptime, cas)` | 任意存储命令（可指定 flags / 过期时间 / CAS） | `Status` |
| `set` / `add` / `replace` / `append` / `prepend` | 对应存储命令；`flags` / `exptime` 以同名可选参数透传，默认 `0` | `Status` |
| `cas(key, value, cas)` | `cas`，带上期望令牌；同样接受可选的 `flags` / `exptime` | `Status` |
| `get(keys)` / `gets(keys)` | `get` / `gets` | `Array[RetrievedValue]` |
| `gat(keys, exptime)` / `gats(keys, exptime)` | `gat` / `gats`，取回的同时把过期时间重置 | `Array[RetrievedValue]` |
| `delete(key)` | `delete` | `Status` |
| `incr(key, delta)` / `decr(key, delta)` | `incr` / `decr` | `UInt64`（执行后的值） |
| `touch(key, exptime)` | `touch`，只续期不取值 | `Status` |
| `version()` | `version` | `String` |
| `stats()` / `stats_of(section)` | `stats` / `stats <section>` | `Array[StatEntry]` |
| `flush_all(delay)` | `flush_all [<delay>]`，`None` 表示立即 | `Status` |
| `verbosity(level)` | `verbosity <level>` | `Status` |
| `cache_memlimit(megabytes)` | `cache_memlimit <megabytes>`，调整 item 内存上限 | `Status` |
| `slabs_reassign(src, dst)` | `slabs reassign <src> <dst>`，`src` 为 `-1` 时由服务器自选 | `Status` |
| `slabs_automove(mode)` | `slabs automove <mode>`（`0` 关 / `1` 开 / `2` 激进） | `Status` |
| `quit()` | `quit` | `Unit` |

上面这些方法都固定 `noreply=false` 并走 `execute`，因此每一个都能拿到服务器的确认。
需要抑制应答时不必绕道编码层：直接构造带 `noreply=true` 的 `Request` 交给 `send`，
`send` 是公开的。

`stats_of(section)` 的 `section` 可以是多个词，`stats_of("cachedump 1 100")` 会发出
`stats cachedump 1 100`；词之间的间隔规则由第七节的校验负责。

`quit` 的语义单独说明：服务器对 `quit` **不回复**，所以它走 `send` 而不是 `execute`。
关闭连接用 postfix `catch` 兜底：`write` 失败时先 `self.conn.close()` 再把错误重新抛出，
写成功时在函数末尾关闭，两种情况都不会泄漏连接。这里是**尽力而为**的关闭——若连关闭本身
也失败了，那个错误被就地吞掉，因为调用方要的是「写不出去」这个原因，而不是「顺手关闭也失败」。

与命令无关的连接管理还有一个入口：`Client::resync()` 直接转发内部的 `Decoder::resync`
（见第五节「缓冲上限与失步恢复」），在 `Desynchronised` 之后、流的 framing 已知重新开始时
（典型如重连）清空缓冲残片，让同一个 `Client` 不必重建就能继续。

## 七、请求校验

校验发生在 `client.mbt`，目的是拦住文本协议无法表达、或会让服务器解析错位的请求。

### key 的合法性（`validate_key`）

1. 非空，且 UTF-8 编码后长度不超过 `MAX_KEY_LENGTH = 250` 字节（服务器按字节计数，不是字符数）；
2. 每个字节的值不能 `<= 0x20`（含空格、制表符、换行等空白与控制字符），也不能是 `0x7F`。

原因是服务器用空格切分命令行，key 里出现空格会导致字段错位；`gets` 解码也依赖 key 不含
控制字符。多字节 UTF-8 的后续字节都 `>= 0x80`，因此正常的中文等非 ASCII key 可以通过。

第 2 条里「哪些字节能站进一个词」被抽成一个共享谓词 `is_word_byte(code)`（即
`code > 0x20 && code != 0x7F`），key 与 `stats` 段名都调用它，两处判定不会各自漂移。

key 来自应用数据，所以**每条拒绝都要能把人指回那条 key**：消息里带上 key 本身、触犯的规则，
有数字可报时再带上字节数。空 key 报 `a key cannot be empty`；超长报出实际字节数与上限
（`key '...' is 251 bytes, more than the 250 bytes a key may hold`）；撞上空白或控制字节时报出
那个字节（`key 'has\ttab' holds a blank or control byte a command line cannot carry: '\t'`）。
key 与那个字节都经 `quote` 处理（见第五节第 6 小节），制表符不会原样进入日志，过长的 key 会被
截断——真实长度仍由旁边的字节数如实报出，两者互相补位。

### 请求级校验（`validate_request`）

`validate_request` 是一条穷尽匹配（`match request { ... }` 覆盖全部变体，新增变体时编译器会
强制补上分支），客户端层的每个写入口在写字节之前都会调用它：

| 请求 | 检查内容 |
| --- | --- |
| `Storage` / `Delete` / `Incr` / `Decr` / `Touch` | 校验 key |
| `Get` / `Gat` | key 列表至少一个（否则生成 `get \r\n` 毫无意义），并逐个校验 key |
| `Stats` | 有子命令时，段名是命令行里的一串「词」：段名可以带参数（`stats detail on`、`stats cachedump 1 100`），词之间只允许**单个**空格，且每个词都要满足 key 的规则（非空、≤250 字节、无空白与控制字符）。空段名、首尾空格、连续两个空格都会留下一个空词，一律拒绝 |
| `FlushAll` | `delay` 为 `Some(n)` 时要求 `n >= 0` |
| `Verbosity` | `level < 0` 即拒绝 |
| `CacheMemlimit` | `megabytes < 0` 即拒绝 |
| `SlabsReassign` | `src` / `dst` 不得小于 `-1`（`-1` 表示由服务器自选源 slab） |
| `SlabsAutomove` | `mode` 只接受 `0` / `1` / `2` |
| `Version` / `Quit` | 无需校验 |

段名的长度上限是**从 key 借来的**：memcached 对 `stats` 段名没有单独的限制，命令行整体按一串
「词」读取，所以「不长于一个 key」必然被接受。本库据此设了一道保守上限，消息写作 `outside the
1..250 bytes this client allows` 而不是声称服务器要求 250 字节，据实说明这是本客户端自己的闸。
整段为空交给长度判据，与超长段名报同一条 `outside the 1..250 bytes`；首空格、尾空格、
连续两个空格留下的空词交给扫描，不论空词出现在什么位置，都收敛到**同一条**
`stats section has an empty word`，错误种类不会随位置变化。

校验只回答“能不能表达成一行合法命令”，不替服务器判断语义：例如 `touch` 一个不存在的 key
是合法的命令行，服务器回 `NOT_FOUND`，本库照样把它编码发出去。

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

两个套件都不需要 memcached 服务端，`moon test` 共 78 个用例（黑盒 50 + 白盒 28）。

### 黑盒测试（`memcached_test.mbt`）

全部通过公开 API 驱动，覆盖：

- **编码**：存储命令行与数据块、CAS 令牌、空值、get/gets 多 key、
  `gat`/`gats`（`<exptime>` 位于 key 之前）、`touch`、delete/incr/decr/quit、
  `version`/`stats`/`stats <section>`/`flush_all`/`verbosity` 的可选参数、
  `cache_memlimit` 与 `slabs reassign`/`automove` 的管理命令行、以及 `noreply`
  一律追加在命令行末尾；
- **解码**：七种状态行（含 `OK`）、计数器数字、单个/多个 `VALUE` 块、未命中（`END`）、
  `VERSION` 行、`STAT` 块（含无值的 STAT 行被拒、`END` 前未结束则继续等待、只收到半行
  `VERSION` 时等待）、数据块以字节数定帧（值内含 `\r\n`）、响应跨 feed 重组、单次 feed
  多响应、服务器错误的三种类别、非法帧（未知行、字段数不对、数据块未以 CRLF 结尾）；
- **客户端**：单连接上 set + get 的完整往返与线上字节断言、cas 透传令牌、便捷存储方法透传
  flags/exptime（线上字节逐字节断言）、计数器返回值、
  `touch`/`gat`/`gats` 往返、`version` 与 `stats` 的取值、`flush_all`/`verbosity`/
  `cache_memlimit`/`slabs` 系命令读回 `OK`、
  `send` 写出 `noreply` 命令且**一个字节都不读**、有应答的命令不能 `send`、无应答的命令不能
  `execute`、`quit`（含写入失败时仍释放连接）、响应中途断连报 `TransportError::Io`、
  未知行报 `Malformed`、key 长度与字符合法性边界（250 通过 / 251 拒绝 / 空串 / 空格 /
  制表符 / 换行）、空 key 列表与管理命令的非法参数（负的 megabytes、小于 -1 的 slab class、
  超出 `0..=2` 的 automove 模式）在写出任何字节之前就被拒绝、声明的字节数远大于可用数据时只是
  等待而不是错误分帧、始终无法定帧的应答被 `with_limit` **当场**判为 `Malformed` 而不是无限缓冲、
  失步的连接经 `Client::resync` 清空残片后照常往返；
- **缓冲上限与块上限**：上限为 0 的解码器仍能解出**已经完整**的响应（上限只在等待时才起作用），
  而同样大小的一段残片会被判为 `Desynchronised(0, 6)` 并如实报出上限与已缓冲字节数；缓冲区
  长度**恰好等于**上限时继续等待（判据是「超过」而不是「达到」），多一个字节才判失步；而块
  连同它的头行与收尾的 `END` 都放不进上限时**当场**报 `Malformed`——连 0 上限的解码器遇到
  `VALUE k 0 1` 也是这个结果，因为头本身就说出了这个块在此处不可能凑齐；`Client::with_limit`
  在上限足够大时不影响正常往返，线上字节与默认解码器一致。

### 白盒测试（`memcached_wbtest.mbt`）

黑盒受公开 API 所限，有些私有路径它够不到；白盒测试直接调用这些函数，覆盖：

- `StorageOp::name`：六个存储命令的命令词映射；
- `find_crlf`：首个分隔符的位置、空输入、只有 `\r` 的输入；
- 数字解析：`is_decimal` 对符号/字母/内嵌空格的拒绝，`parse_decimal` 的 u64 上界
  （`18446744073709551615` 通过 / `...616` 拒绝），`parse_decimal_int` 的 i32 上界
  （`2147483647` 通过 / `2147483648` 拒绝）；
- `parse_value_header`：四/五字段、非 ASCII key、字段数不对、非数字字段、超界值；以及
  `<bytes>` 的块上限——它由**传入的 `limit` 决定**，且判据算的是「块 + 头行 + 块尾 `\r\n` +
  `END` 行」能否装进 `limit`（分帧部分直接取常量 `VALUE_RETRIEVAL_FRAMING` 的字节数，不手算）：
  memcached 自身的 1 MiB item 上限（`1048576`）连分帧也放得进 `DEFAULT_BUFFER_LIMIT`，属于
  「还在路上」的块必须通过，而恰好等于上限的声明会被拒绝（分帧没有容身之处）；换成 `limit=64`
  时 `VALUE foo 0 41` 的 14（头行）+ 41（数据）+ 9（`VALUE_RETRIEVAL_FRAMING`）= 64 恰好通过，
  再多一个字节就被拒绝；
- 解码细节：`decode_status` 原样带回 offset、`decode_line` 把 UTF-8 key 还原成文本、
  `decode_response` 对 64 个 `VALUE` 块的整段解码与消耗字节数、以及“响应不完整不是错误”
  （只返回 `None` 等待更多数据）；
- `STAT` 行：只在**第一个**空格处切分（值里可以带空格，如 `libevent 2.1.12-stable`）、
  子命令把维度嵌进名字（`items:1:number`）、缺值/缺分隔符/非 `STAT` 行/空名字
  （`STAT  pid 1`）均报 `Malformed`；
- 错误消息的转义与截断：普通文本原样保留，回车换行等控制字符被转义成单行可读的形式，
  `0x7F` 写成 `\u{7f}`，超过 64 个字符的部分被截断并以 `...` 结尾；
- `stats` 的定帧：**首行就属于数据段**（`STAT pid 1234\r\nEND\r\n` 必须解出 1 条而不是 0 条），
  缺少末尾 `END` 时返回 `None` 继续等待，中途冒出 `STORED` 这类非 `STAT`/`END` 行才算错帧；
- `VERSION` 行：偏移量取前缀的字节长度，否则版本串会剩下一个前导空格；
- `Decoder` 的缓冲上限：`limit()` 默认是 `DEFAULT_BUFFER_LIMIT`、`with_limit` 如实回报；
  未越界时只等待（并如实报告 `buffered()`），越界时抛
  `ProtocolError::Desynchronised(limit, buffered)`；而头里声明的块连分帧都放不进 `limit` 时
  **不等缓冲填满**就用 `Malformed` 报出，消息里同时给出声明字节数、计入分帧后的需求与上限；
  多块检索逐头按**整份** `limit` 判定、而不是按前面块用剩的额度，所以这道头检查对整段序列只是
  必要条件——每个块单独都放得下、合起来超过 `limit` 的响应不会被它拦下：整段一次到齐时照常解出
  全部块，同样的字节若缺了收尾的 `END` 堆在缓冲里，才由 `next()` 按 `Desynchronised` 报出；
  `resync()` 丢弃失步残片后，解码器能立刻从下一个完整响应上重新同步；
- `expect_values` / `expect_status` / `expect_counter`：响应种类不符即 `Malformed`；
- 校验：`validate_key` 对 `0x1F`、`0x7F` 等控制字符与长度边界的判定（含多字节字符按
  UTF-8 字节计数的 249 通过 / 252 拒绝），并且逐个断言拒绝时的**消息原文**——空 key 那条不带
  参数，超长那条报出 251 与 250 两个数，撞上制表符、空格、`0x7F` 时把违规字节转义后附在 key
  后面；`validate_request` 覆盖每条带 key 的命令，以及三条管理命令的参数边界
  （`cache_memlimit` 拒绝负数、`slabs reassign` 以 `-1` 为下限、`slabs automove` 只收 `0..=2`）；
  `stats` 的段名另有一组用例——`detail on`、`cachedump 1 100` 这类多词段名通过，而空段名、
  首尾空格、连续两个空格、含制表符的段名都拒绝；空段名与超长段名同走长度判据，报出实际字节数
  与 `1..250`；首空格、尾空格、连续两个空格留下的空词收敛到同一条 `stats section has an empty
  word`；非法字节被转义后随段名带回。

### 运行方式

```shell
moon test          # 跑测试
moon run cmd/main  # 跑演示程序
moon info && moon fmt
```

`cmd/main/main.mbt` 用 `ScriptedConnection` 演示四段内容：请求编码结果（带转义，便于看清
`\r\n` 分帧，含 `gat`、`noreply` 的 `del!`、`stats items`、`flush_all 10`）、单连接客户端的
set/get 往返与线上字节、`noreply` 与 `version`/`stats`/`flush_all`/`cache_memlimit` 这些管理命令（`send` 出去的
`delete gone noreply` 同样出现在线上字节里）、以及增量解码器“半个响应等待、补齐后解出”。

## 十、边界与已知限制

- **未实现流水线**：`execute` 一次只发一个请求、等一个响应。多发多收需要新的批处理 API
  （解码器已具备该能力；`send` 也能先把若干个 `noreply` 命令一次性排出去，只是收不到各自的结果）。
- **`noreply` 的错误会错位**：服务器对 `noreply` 命令**仍然可能**返回错误行（例如
  `CLIENT_ERROR bad data chunk`、`SERVER_ERROR out of memory`）。`send` 不读这些字节，它们会留在
  缓冲区里，被**下一条** `execute` 当成自己的响应，从而报出位置不对的 `Malformed` 或 `Remote`。
  文本协议的 `noreply` 只抑制正常应答，并不抑制错误；需要严格的错误归属时请用 `execute`。
- **失步要靠调用方恢复**：`Decoder` 只抛出 `ProtocolError::Desynchronised(limit, buffered)`，
  不会自己丢弃残片；要先显式 `Client::resync()`（或直接操作 `Decoder::resync()`，或另建
  `Client`）才能重新同步，在此之前缓冲区里的字节始终还在。
- **有字节上限，没有时间上限**：`DEFAULT_BUFFER_LIMIT`（8 MiB）拦的是“缓冲无限增长”，
  不是“响应迟迟不来”。`Connection::read` 阻塞多久完全由实现决定，本库不做超时。同一个上限
  也界定了 `VALUE` 头里 `<bytes>` 的合法范围：块要连同头行、块尾的 `\r\n` 与收尾的 `END` 行
  一起装进缓冲区，装不下的声明会因为永远等不到数据而**当场**判为 `Malformed`（见第五节）。
  因此服务端若配置了比当前上限更大的单条 item 上限，默认配置下本库无法表达——需要放宽带块时
  用 `Decoder::with_limit` / `Client::with_limit`。
- **仍未覆盖的协议**：二进制协议、meta 协议（`mg`/`ms`/`md`/`ma`）、SASL 认证、UDP 传输、
  压缩值等都不支持；文本协议这边的管理命令覆盖 `stats [<section>]`（段名本身可带参数，
  如 `stats detail on`）、`cache_memlimit` 与 `slabs reassign`/`automove`，`lru_crawler`、
  `lru tuner`、`shutdown` 等仍未支持。
- **校验不做数值范围检查**：`flags`、`exptime`、`cas` 的取值本身不校验，`exptime` 为负会直接
  编码成 `-1` 交给服务器裁决；真正越界的是**解码**侧——`parse_decimal` 在 u64 上界之外报
  `Malformed` 而不是静默回绕，`parse_decimal_int` 对超过 `i32` 上界的字段同样报错。
- **一次取回的 `VALUE` 块全部驻留内存**：`decode_value_blocks` 已由递归改为循环，不再随块数
  加深调用栈，但一个响应里的全部块仍会同时构造出来，缓冲区也会持有整段字节直到 `next()`
  消费掉。
- **计数器命令对非数字值**：memcached 会回 `CLIENT_ERROR cannot increment or decrement
  non-numeric value`，在本库中表现为 `ProtocolError::Remote(Client, ...)`。
- **`quit` 不读响应**：这是协议约定（服务器不回复）；若调用方在 `quit` 之后继续用同一
  `Client`，行为未定义。
- **`ScriptedConnection` 仅用于测试**：它在预置的 chunk 回放完之后返回空字节，真实实现（socket 等）需要自行
  实现 `Connection` 并遵守同样的约定——空结果表示对端关闭。

## 十一、扩展示例：新增一条命令

`cache_memlimit`、`slabs reassign`、`slabs automove` 三条管理命令就是按这条固定路线加入的。
以 `cache_memlimit <megabytes> [noreply]` 为例，改动点固定为五处：

1. `Request` 增加变体（`CacheMemlimit(megabytes~ : Int, noreply~ : Bool)`）；
2. `Request::to_bytes` 增加对应分支，`noreply` 用现成的 `write_noreply` 追加；
3. `Request::expects_reply` 增加分支 —— 这条命令有应答，返回 `!noreply`（穷尽匹配会强制你补上
   这一步，否则编译不过）；
4. `client.mbt` 的 `validate_request` 增加范围校验分支（`megabytes < 0` 即拒绝，同样保持穷尽匹配）；
5. `Client` 增加便捷方法 `cache_memlimit(megabytes)`，并用 `expect_status` 收尾。

`noreply` 是上述五步里的横切关注点：`to_bytes` 负责把它写进命令行，`expects_reply` 负责据此
决定 `execute` 还是 `send` 可用。两步都做完，新命令才不会被误用在错误的入口上。

若要接真实网络，只需给 socket 实现 `Connection`：`read` 在无数据时阻塞，返回空表示对端关闭，
其余逻辑无需改动。


**边界与后续规划**

当前已明确记录并接受以下边界，作为后续扩展范围：

- **未实现流水线**：`execute` 一次只发一个请求、等一个响应；解码器已具备多发多收的能力，后续
  可在此之上新增批处理 API；

- **`noreply` 的错误会错位**：服务器对 `noreply` 命令仍可能返回错误行，`send` 不读这些字节，
  它们会被下一条 `execute` 当成自己的响应；需要严格的错误归属时改用 `execute`；

- **有字节上限，没有时间上限**：`Connection::read` 阻塞多久完全由实现决定，本库不做超时；
  服务端若配置了比当前上限更大的单条 item 上限，需要用 `Decoder::with_limit` /
  `Client::with_limit` 放宽；

- **仍未覆盖的协议**：二进制协议、meta 协议（`mg` / `ms` / `md` / `ma`）、SASL 认证、UDP 传输、
  压缩值等均不支持。

后续按以下方向推进：补上真实 socket 的 `Connection` 实现与连接池示例；增加流水线批处理 API；
视需要在保持三层结构不变的前提下接入更完整的协议特性（meta、二进制协议等）。

## 扩展方向与难度

### 短期：低成本、零架构风险

| 方向 | 难度 | 评估 |
| --- | --- | --- |
| 超时支持 | ★ 很低（本库侧） | `Connection::read` 的阻塞语义本就是实现定义，超时天然属于 socket 实现的 read timeout；本库只需文档说明。**不建议**在 API 里加截止时间参数，会污染三层结构 |
| 压缩值 | ★★ 低 | 纯客户端变换：存前压缩 + flags 置标志位，取后按 flags 解压，协议零改动。唯一风险是 MoonBit 生态缺少现成 deflate/zlib 绑定 |

### 中期：架构可承载，工作集中在一处

| 方向 | 难度 | 评估 |
| --- | --- | --- |
| 流水线批处理 API | ★★ 低-中 | 解码侧零改动（`Decoder` 已具备多发多收）。工作在 client：写出 N 个请求后按 `expects_reply` 计数读回、按序配对。需要定义清楚的点：混入 `noreply` 时的计数规则、某条响应是 `Remote` 错误时是否继续收后续响应 |
| 真实 socket `Connection` + 连接池 | ★★★ 中 | 本库零改动，难点全在外部：首选目标 wasm-gc 无 socket 能力，需切 native/JS 宿主或等待 async 生态成熟；连接池（checkout/checkin + 用 `version` 做健康探测）依赖 socket 先落地 |
| meta 协议（`mg` / `ms` / `md` / `ma`） | ★★★ 中 | 同为文本行协议，可落在现有三层内：新增 `Request` 变体 + 响应类型（`HD` / `VA` / `EN` / `EX`…）+ `decode_response` 新分派分支。复杂度在 meta 响应的 flag token 语法比 `VALUE` 头丰富，解析工作量明显大于普通命令 |

### 长期/重构级

| 方向 | 难度 | 评估 |
| --- | --- | --- |
| 二进制协议（含 SASL） | ★★★★ 中高 | 24 字节定长头 + opaque 令牌配对，与文本协议分帧完全不同，等于新写一套 codec（传输层可复用）。收益：天然支持流水线乱序配对与 SASL。建议做成独立模块，不影响现有 API。注意 SASL 在文本协议中没有对应物，只能随二进制协议落地 |
| UDP 传输 | — 建议移除 | memcached 自 1.6.0 起已删除 UDP 支持，投入无意义，建议从规划里划掉 |
| `noreply` 错误错位 | 不可根治 | 文本协议层面无法把游离的错误行归属到具体命令，现有「改用 `execute`」就是正确缓解；根治只有二进制协议的 opaque |

### 附带：一个不改 API 的内部优化

`Decoder::feed` 每次 `Bytes::add` 全量拷贝缓冲区，高频喂入大块时有 O(n²) 累积风险；可改为滑动窗口 + 惰性压缩。难度 ★★，`.mbti` 不变，纯内部重构。

### 建议路线

`flags/exptime` 透传与「管理子命令 + `Client::resync`」已完成（`cache_memlimit` / `slabs reassign` /
`slabs automove` 与 `Client::resync` 已就位）。后续：`流水线批处理`（收益最大、成本最低的一个）→
`socket + 连接池`（取决于 MoonBit 生态）→ `meta 协议` / `二进制协议`（按需）。UDP 从规划移除。