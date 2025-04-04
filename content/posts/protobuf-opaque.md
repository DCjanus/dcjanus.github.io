---
title: "Go Protobuf：新的 Opaque API"
date: 2025-04-05T00:38:32+08:00
draft: false
authors: ['DCjanus']
tags: ['golang', 'protobuf', 'microservice', 'api-design']
---

> 本文是对 [Go 官方博客文章](https://go.dev/blog/protobuf-opaque) 的中文翻译，原文作者为 Michael Stapelberg，发表于 2024 年 12 月 16 日。

[Protocol Buffers (Protobuf)](https://protobuf.dev/) 是 Google 的语言无关数据交换格式。

2020 年 3 月，我们发布了 `google.golang.org/protobuf` 模块，这是对 Go Protobuf API 的重大重构。该包引入了一流的反射支持、动态 protobuf 实现以及 `protocmp` 包，简化了测试。

那次发布引入了一个新的 protobuf 模块和新的 API。今天，我们发布了一个额外的 API，用于生成的代码，即由协议编译器（`protoc`）创建的 `.pb.go` 文件中的 Go 代码。这篇博客文章解释了创建新 API 的动机，并展示了如何在项目中使用它。

需要明确的是：我们不会移除任何内容。我们将继续支持现有的生成代码 API，就像我们仍然支持较旧的 protobuf 模块（通过包装 `google.golang.org/protobuf` 实现）一样。Go 致力于向后兼容性，这也适用于 Go Protobuf！

## 背景：现有的 Open Struct API

我们现在将现有的 API 称为 Open Struct API，因为生成的结构体类型允许直接访问。在下一节中，我们将看到它与新的 Opaque API 有何不同。

要使用协议缓冲区，首先需要创建一个 `.proto` 定义文件，如下所示：

```
edition = "2023";  // proto2 和 proto3 的继任者

package log;

message LogEntry {
  string backend_server = 1;
  uint32 request_size = 2;
  string ip_address = 3;
}
```

然后，运行协议编译器（protoc）生成如下代码（在 `.pb.go` 文件中）：

```
package logpb

type LogEntry struct {
  BackendServer *string
  RequestSize   *uint32
  IPAddress     *string
  // …内部字段省略…
}

func (l *LogEntry) GetBackendServer() string { … }
func (l *LogEntry) GetRequestSize() uint32   { … }
func (l *LogEntry) GetIPAddress() string     { … }
```

现在，你可以从 Go 代码中导入生成的 `logpb` 包，并调用 `proto.Marshal` 等函数将 `logpb.LogEntry` 消息编码为 protobuf 线格式。

你可以在[生成的代码 API 文档](https://pkg.go.dev/google.golang.org/protobuf/proto#Message)中找到更多详细信息。

### 现有的 Open Struct API：字段存在性

这个生成的代码的一个重要方面是如何模拟*字段存在性*（字段是否已设置）。例如，上面的示例使用指针来模拟存在性，因此你可以将 `BackendServer` 字段设置为：

1. `proto.String("zrh01.prod")`：字段已设置，值为 "zrh01.prod"
2. `proto.String("")`：字段已设置（非 `nil` 指针），但值为空
3. `nil` 指针：字段未设置

如果你习惯生成的代码没有指针，你可能使用的是以 `syntax = "proto3"` 开头的 `.proto` 文件。字段存在性行为多年来发生了变化：

- `syntax = "proto2"` 默认使用*显式存在性*
- `syntax = "proto3"` 最初使用*隐式存在性*（无法区分情况 2 和 3，两者都表示为空字符串），但后来通过 `optional` 关键字允许选择显式存在性
- `edition = "2023"`，作为 proto2 和 proto3 的继任者，默认使用*显式存在性*

## 新的 Opaque API

我们创建了新的*Opaque API*，以解耦生成的代码 API 与底层内存表示。现有的 Open Struct API 没有这种分离：它允许程序直接访问 protobuf 消息内存。例如，可以使用 `flag` 包将命令行标志值解析到 protobuf 消息字段中：

```
var req logpb.LogEntry
flag.StringVar(&req.BackendServer, "backend", os.Getenv("HOST"), "…")
flag.Parse() // 从 -backend 标志填充 BackendServer 字段
```

这种紧密耦合的问题在于，我们永远无法更改 protobuf 消息在内存中的布局方式。解除这一限制可以实现许多实现改进，我们将在下面看到。

新的 Opaque API 有什么变化？以下是上述示例的生成代码将如何变化：

```
package logpb

type LogEntry struct {
  xxx_hidden_BackendServer *string // 不再导出
  xxx_hidden_RequestSize   uint32  // 不再导出
  xxx_hidden_IPAddress     *string // 不再导出
  // …内部字段省略…
}

func (l *LogEntry) GetBackendServer() string { … }
func (l *LogEntry) HasBackendServer() bool   { … }
func (l *LogEntry) SetBackendServer(string)  { … }
func (l *LogEntry) ClearBackendServer()      { … }
// …
```

使用 Opaque API，结构体字段被隐藏，不再可以直接访问。相反，新的访问器方法允许获取、设置或清除字段。

### Opaque 结构体使用更少的内存

我们对内存布局所做的一个改变是更高效地模拟基本字段的字段存在性：

- 现有的 Open Struct API 使用指针，这增加了字段的空间成本 64 位字。
- Opaque API 使用位字段，每个字段需要一位（忽略填充开销）。

使用更少的变量和指针也减轻了分配器和垃圾收集器的负担。

性能改进在很大程度上取决于你的协议消息的形状：这个改变只影响基本字段，如整数、布尔值、枚举和浮点数，但不影响字符串、重复字段或子消息（因为这些类型的改进效果较小）。

我们的基准测试结果显示，具有少量基本字段的消息表现出与之前一样好的性能，而具有更多基本字段的消息解码时分配次数显著减少：

```
             │ Open Struct API │             Opaque API             │
             │    allocs/op    │  allocs/op   vs base               │
Prod#1          360.3k ± 0%       360.3k ± 0%  +0.00% (p=0.002 n=6)
Search#1       1413.7k ± 0%       762.3k ± 0%  -46.08% (p=0.002 n=6)
Search#2        314.8k ± 0%       132.4k ± 0%  -57.95% (p=0.002 n=6)
```

减少分配也使解码 protobuf 消息更高效：

```
             │ Open Struct API │             Opaque API            │
             │   user-sec/op   │ user-sec/op  vs base              │
Prod#1         55.55m ± 6%        55.28m ± 4%  ~ (p=0.180 n=6)
Search#1       324.3m ± 22%       292.0m ± 6%  -9.97% (p=0.015 n=6)
Search#2       67.53m ± 10%       45.04m ± 8%  -33.29% (p=0.002 n=6)
```

（所有测量均在 AMD Castle Peak Zen 2 上进行。在 ARM 和 Intel CPU 上的结果类似。）

注意：具有隐式存在性的 proto3 同样不使用指针，所以如果你是从 proto3 迁移过来的，你不会看到性能改进。如果你使用显式存在性（通过 `optional` 关键字），你会看到改进。

### 动机：减少指针比较错误

使用指针模拟字段存在性容易导致指针相关的错误。

考虑一个枚举，在 `LogEntry` 消息中声明：

```
message LogEntry {
  enum DeviceType {
    DESKTOP = 0;
    MOBILE = 1;
    VR = 2;
  };
  DeviceType device_type = 1;
}
```

一个简单的错误是比较 `device_type` 枚举字段，如下所示：

```
if cv.DeviceType == logpb.LogEntry_DESKTOP.Enum() { // 错误！
```

你发现这个错误了吗？条件比较的是内存地址而不是值。因为 `Enum()` 访问器在每次调用时都分配一个新变量，所以条件永远不会为真。检查应该写成：

```
if cv.GetDeviceType() == logpb.LogEntry_DESKTOP {
```

新的 Opaque API 防止这种错误：因为字段被隐藏，所有访问都必须通过 getter。

### 动机：减少意外共享错误

让我们考虑一个稍微复杂一点的指针相关错误。假设你正在尝试稳定一个在高负载下失败的 RPC 服务。以下请求中间件的一部分看起来是正确的，但每当只有一个客户发送高流量请求时，整个服务就会崩溃：

```
logEntry.IPAddress = req.IPAddress
logEntry.BackendServer = proto.String(hostname)
// redactIP() 函数将 IPAddress 编辑为 127.0.0.1，
// 意外地不仅在 logEntry 中，而且在 req 中！
go auditlog(redactIP(logEntry))
if quotaExceeded(req) {
    // 错误：所有请求都到这里，无论它们的来源如何。
    return fmt.Errorf("server overloaded")
}
```

你发现这个错误了吗？第一行意外地复制了指针（从而在 `logEntry` 和 `req` 消息之间共享了指向的变量），而不是它的值。它应该写成：

```
logEntry.IPAddress = proto.String(req.GetIPAddress())
```

新的 Opaque API 防止这个问题，因为 setter 接受一个值（`string`）而不是指针：

```
logEntry.SetIPAddress(req.GetIPAddress())
```

### 动机：修复尖锐边缘：反射

要编写不仅适用于特定消息类型（例如 `logpb.LogEntry`），而且适用于任何消息类型的代码，需要某种反射。前面的例子使用了一个函数来编辑 IP 地址。要处理任何类型的消息，它可以定义为 `func redactIP(proto.Message) proto.Message { … }`。

多年前，实现像 `redactIP` 这样的函数的唯一选择是使用 Go 的 reflect 包，这导致了非常紧密的耦合：你只有生成器输出，必须反向工程输入 protobuf 消息定义可能是什么样子。`google.golang.org/protobuf` 模块发布（2020 年 3 月）引入了 [Protobuf 反射](https://pkg.go.dev/google.golang.org/protobuf/reflect/protoreflect)，这应该始终是首选：Go 的 `reflect` 包遍历数据结构的表示，这应该是一个实现细节。Protobuf 反射遍历协议消息的逻辑树，而不考虑其表示。

不幸的是，仅仅*提供* protobuf 反射是不够的，仍然会暴露一些尖锐的边缘：在某些情况下，用户可能会意外地使用 Go 反射而不是 protobuf 反射。

例如，使用 `encoding/json` 包（它使用 Go 反射）编码 protobuf 消息在技术上是可能的，但结果不是规范的 Protobuf JSON 编码。请改用 `protojson` 包。

新的 Opaque API 防止这个问题，因为消息结构体字段被隐藏：意外使用 Go 反射将看到一个空消息。这足够清晰，可以引导开发者使用 protobuf 反射。

### 动机：使理想的内存布局成为可能

"更高效的内存表示"部分的基准测试结果已经表明，protobuf 性能在很大程度上取决于特定用法：消息是如何定义的？哪些字段被设置？

为了让 Go Protobuf 对*每个人*都尽可能快，我们不能实现只帮助一个程序但损害其他程序性能的优化。

Go 编译器曾经处于类似的情况，直到 Go 1.20 引入了配置文件引导优化（PGO）。通过记录生产行为（通过分析）并将该配置文件反馈给编译器，我们允许编译器为*特定程序或工作负载*做出更好的权衡。

我们认为使用配置文件来优化特定工作负载是 Go Protobuf 进一步优化的一个有前途的方法。Opaque API 使这些成为可能：程序代码使用访问器，当内存表示改变时不需要更新，所以我们可以，例如，将很少设置的字段移动到溢出结构体中。

## 迁移

你可以按照自己的时间表迁移，或者根本不迁移——现有的 Open Struct API 不会被移除。但是，如果你不使用新的 Opaque API，你将无法受益于其改进的性能，或针对它的未来优化。

我们建议你为新开发选择 Opaque API。Protobuf Edition 2024（如果你还不熟悉，请参阅 [Protobuf Editions 概述](https://protobuf.dev/editions/overview)）将使 Opaque API 成为默认选项。

### 混合 API

除了 Open Struct API 和 Opaque API 之外，还有混合 API，它通过保持结构体字段导出而使现有代码继续工作，但也通过添加新的访问器方法启用迁移到 Opaque API。

使用混合 API，protobuf 编译器将在两个 API 级别生成代码：`.pb.go` 使用混合 API，而 `_protoopaque.pb.go` 版本使用 Opaque API，可以通过 `protoopaque` 构建标签选择。

### 将代码重写为 Opaque API

请参阅[迁移指南](https://pkg.go.dev/google.golang.org/protobuf/cmd/protoc-gen-go/internal_gengo#Migration)获取详细说明。高级步骤是：

1. 启用混合 API。
2. 使用 `open2opaque` 迁移工具更新现有代码。
3. 切换到 Opaque API。

### 发布生成代码的建议：使用混合 API

小的 protobuf 使用可以完全存在于同一个仓库中，但通常，`.proto` 文件在不同项目之间共享，这些项目由不同的团队拥有。一个明显的例子是当涉及不同的公司时：要从你的项目调用 Google API（使用 protobuf），请使用 Google Cloud Client Libraries for Go。将 Cloud Client Libraries 切换到 Opaque API 不是一个选项，因为这将是一个破坏性的 API 更改，但切换到混合 API 是安全的。

我们对发布生成代码（`.pb.go` 文件）的包的建议是请切换到混合 API！请同时发布 `.pb.go` 和 `_protoopaque.pb.go` 文件。`protoopaque` 版本允许你的消费者按照自己的时间表迁移。

### 启用延迟解码

一旦你迁移到 Opaque API，延迟解码就可用了（但未启用）！🎉

要启用：在你的 `.proto` 文件中，用 `[lazy = true]` 注解标注你的消息类型字段。

要选择退出延迟解码（尽管有 `.proto` 注解），[protolazy 包文档](https://pkg.go.dev/google.golang.org/protobuf/internal/impl#LazyMessage)描述了可用的选择退出，它们影响单个 Unmarshal 操作或整个程序。

## 下一步

通过在过去的几年中以自动化方式使用 open2opaque 工具，我们已经将 Google 的绝大多数 `.proto` 文件和 Go 代码转换为 Opaque API。随着我们将越来越多的生产工作负载迁移到它，我们不断改进 Opaque API 实现。

因此，我们预计你在尝试 Opaque API 时不会遇到问题。如果你确实遇到任何问题，请在 [Go Protobuf 问题跟踪器](https://github.com/golang/protobuf/issues)上告诉我们。

Go Protobuf 的参考文档可以在 [protobuf.dev → Go Reference](https://protobuf.dev/reference/go/) 找到。
