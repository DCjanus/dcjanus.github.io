---
title: "Streaming Lzf Decode"
date: 2025-07-04T01:34:15+08:00
draft: false
authors: ["DCjanus"]
tags: ["Redis", "Rust", "Compression"]
---

我最近在业余时间重写一个之前为工作开发的 Redis RDB 解析工具，旧版工具在处理大 Key 时内存占用过高，有时会触发容器的内存限制，导致解析失败。因此，新版本的核心目标是实现增量解析。

Redis 中对字符串对象，允许使用 LZF 压缩来节省空间，但常见 LZF 实现都只支持一次性解压，仍无法彻底规避内存问题。简单了解 LZF 算法后，发现其实现极为简单，且有流式解压的潜力，因此决定自己实现一个流式解压器。

<!--more-->

## 缘起：从高内存占用到增量解析

我日常工作的一部分是维护公司内部的 Redis 缓存平台，为了降低运维成本、提升排查问题的效率，写过一个解析 RDB 输出报告的工具。最初版本使用的是一个简单的递归下降解析器，实现直接，但在处理大 Key 时内存占用过高，有时会触发容器的内存限制，导致解析失败。

为了彻底解决这个问题，新版本的核心目标是实现**增量解析**（Incremental Parsing）：将 RDB 文件看作一个数据流，边读边解析，从而将内存占用维持在一个固定的、可预测的水平。

## 瓶颈：不支持流式解压的 LZF

增量解析方案在处理大部分数据类型时都工作的很好，直到我遇到了 RDB 中经过 LZF 压缩的字符串。

Redis 为了节省空间，会对满足特定条件的字符串对象进行 LZF 压缩。问题在于，不管是 C 语言的 `liblzf`[^liblzf] 还是社区流行的 Rust `lzf`[^rust-lzf] 库，它们提供的接口都是一次性的：你需要提供完整的压缩数据块，然后它们一次性返回所有解压后的数据。

```rust
// 典型的 LZF 解压接口
// 需要一次性读入所有压缩数据
fn decompress(compressed: &[u8], uncompressed_size: usize) -> Result<Vec<u8>>;
```

这一下就回到了原点。如果一个被压缩的 Value 本身体积很大（比如几十上百MB），即使它是被压缩的，一次性加载和解压仍然会带来巨大的内存压力，增量解析的优势在 LZF 这里就荡然无存了。

## 深入：LZF 算法分析

经过一番研究，LZF 的压缩格式天生就适合流式处理。它的数据流由一系列的指令块（Action）构成，每个指令块要么是"原文拷贝"，要么是"字典回溯拷贝"。解压器只需按顺序读取和执行这些指令即可，无需一次性加载全部数据。

每个指令块都由一个控制字节（Control Byte）开头，其格式决定了指令的类型和参数：

### 1. 原文拷贝 (Literal Run)

当控制字节 `ctrl` 的值小于 32（即 `ctrl < 0b0010_0000`）时，表示这是一个原文拷贝指令。

- **格式**: `000LLLLL [literal data]`
- `LLLLL`: 低 5 位表示原文数据的长度减 1。因此，原文长度为 `ctrl + 1`。
- **数据**: 控制字节之后紧跟着相应长度的、未经压缩的原文数据。

这种指令块非常直接，解压器只需读取控制字节，计算出长度，然后从输入流中直接复制相应字节到输出即可。

### 2. 回溯拷贝 (Back-reference)

当控制字节 `ctrl` 的值大于等于 32 时，表示这是一个回溯拷贝指令，需要从已经解压的历史数据（字典）中复制内容。其格式稍微复杂一些，控制字节被分成了两部分：

- **格式**: `LLLooooo OOOOOOOO [LLLLLLLL]`
- `LLL`: 高 3 位用于编码拷贝长度（Length）。
- `ooooo`: 低 5 位是回溯距离（Offset）的高位。

长度和距离的计算规则如下：

- **长度 (Length)**:
  - 如果高 3 位 `LLL` 的值不等于 7 (`0b111`)，那么拷贝长度就是 `LLL + 2`。
  - 如果 `LLL` 等于 7，意味着长度超过了当前能表示的范围，需要从下一个字节中读取一个增量。最终长度为 `7 + 2 + next_byte`。
- **距离 (Offset)**:
  - 由控制字节的低 5 位 `ooooo` 和紧随其后的一个字节 `OOOOOOOO` 共同构成一个 13 位的偏移量。计算公式为 `(ooooo << 8) + OOOOOOOO + 1`。

由于每个指令块的解析都只依赖于当前输入流的位置和已经产生的输出（字典），而不需要预知未来的数据，这为流式解压提供了理论基础。

## 实现：流式解压器

有了理论基础，实现起来就清晰多了。我没有将它实现为一个标准的 `io::Read` 装饰器，而是构建了一个 `LzfChunkDecoder` 状态机。它拥有一个 `feed` 方法，从一个输入缓冲区读取压缩数据，解压后推送到一个输出缓冲区。

它的内部状态大致如下：

```rust
const RING_SIZE: usize = 8 * 1024;

#[derive(Debug, Clone, Default)]
pub struct LzfChunkDecoder {
    buff: Vec<u8>,
    tail: usize,
}
```

其中，`buff` 和 `tail` 构成了一个 8KB 大小的环形缓冲区（Ring Buffer），用于存储最近解压出的数据，也就是"字典"。`feed` 方法是整个解码器的核心，其逻辑可以简化为以下伪代码：

```rust
fn feed(&mut self, i_buf: &mut Buffer, o_buf: &mut Buffer) -> AnyResult {
    // 1. 从输入缓冲中解析出下一个指令
    let (remaining_input, action) = Self::read_action(i_buf.as_slice())?;

    if action.offset == 0 {
        // 2a. 如果是"原文拷贝"指令
        // 3a. 从输入缓冲读取`action.length`长度的数据
        // 4a. 将数据推入输出缓冲，并更新环形缓冲区
        // ...
    } else {
        // 2b. 如果是"字典拷贝"指令
        // 3b. 从环形缓冲区中按`action.offset`和`action.length`找到数据
        // 4b. 将数据推入输出缓冲，并更新环形缓冲区
        // ...
    }

    // 5. 更新输入缓冲的消费位置
    i_buf.consume_to(...);
    Ok(())
}
```

将解析指令（`read_action`）和执行指令（`feed`中的拷贝逻辑）分离，`read_action` 是一个纯函数，它只负责解析，不产生副作用。

这样一来，`LzfChunkDecoder` 的内存占用就只由其内部环形缓冲区的大小（8KB）决定，与原始压缩数据的体积无关，从而满足了增量解析对内存控制的要求。

## 引用

[^liblzf]: liblzf homepage: <http://oldhome.schmorp.de/marc/liblzf.html>

[^rust-lzf]: rust-lzf on crates.io: <https://crates.io/crates/lzf>
