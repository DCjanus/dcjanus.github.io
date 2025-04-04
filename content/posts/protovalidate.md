---
title: "protoc-gen-validate (PGV) 与 protovalidate：ProtoBuf 验证工具的演进"
date: 2025-04-04T23:58:52+08:00
authors: ['DCjanus']
tags: ['golang', 'protobuf', 'microservice', 'kratos']
---

## 引言

在微服务架构中，接口参数验证是一个常见且重要的需求。B 站开源的 [Kratos](https://github.com/go-kratos/kratos) 框架围绕 ProtoBuf 和 DDD 设计，侵入性低，方便根据业务需求进行裁剪。

在 Kratos 官方模板中，开发者可以通过 ProtoBuf 定义服务接口，进而生成 OpenAPI 文档、客户端代码、服务端代码等。此外，官方文档还介绍了使用 `protoc-gen-validate` 插件生成数据验证代码，简化数据验证逻辑。

本文将详细介绍 `protoc-gen-validate` (PGV) 及其继任者 `protovalidate`，探讨它们的特性、差异及在 Kratos 中的应用。

## PGV：ProtoBuf 验证的奠基者

### 什么是 PGV

`protoc-gen-validate` (PGV) 是 Envoy 团队开发的一款 protoc 插件，它允许开发者在 Proto 文件中定义校验规则，并自动生成对应的验证代码。这种方式将验证规则与接口定义紧密结合，确保文档与实现的一致性。

### 工作原理

PGV 的工作原理简洁明了：

1. 在 Proto 文件中定义验证规则
2. 使用 PGV 插件生成验证代码
3. 在服务端或客户端调用生成的验证方法

生成的验证代码通常包含 `Validate()` 和 `ValidateAll()` 方法：
- `Validate()`：遇到第一个错误即返回
- `ValidateAll()`：收集所有错误并一次性返回

### 使用示例

以下是一个简单的 PGV 使用示例：

```proto
syntax = "proto3";

package example;

service HelloService {
    rpc SayHello (HelloRequest) returns (HelloResponse) {}
}

message HelloRequest {
    string name = 1 [(validate.rules).string.min_len = 1];
}

message HelloResponse {
    string message = 1;
}
```

通过定义 `validate.rules` 选项，PGV 会生成相应的验证代码，确保 `name` 字段的长度至少为 1。

### PGV 的局限性

尽管 PGV 提供了强大的验证功能，但它也存在一些局限性：

1. 只能处理简单的验证规则，复杂的业务逻辑验证需要自行实现
2. 验证规则与 Proto 定义耦合，修改验证规则需要重新生成代码
3. 多语言一致性存在问题，不同语言生成的验证逻辑可能存在细微差异

## protovalidate：PGV 的继任者

### 诞生背景

为了解决 PGV 的局限性，buf 团队开发了 `protovalidate`，它是 PGV 的继任者，提供了更灵活、更强大的验证功能。

### 主要改进

相比 PGV，protovalidate 有以下主要改进：

1. **更丰富的验证规则**：支持更多的数据类型和验证规则
2. **更灵活的验证方式**：支持通过 CEL 自定义验证函数和条件验证
3. **更好的错误处理**：提供更详细的错误信息和更好的错误处理机制
4. **更好的跨语言一致性**：基于 CEL 定义语言无关的验证规则，简化多语言实现

## 在 Kratos 中的应用

### PGV 的集成方式

过去 Kratos 官方代码中提供了 PGV 的中间件实现，只需要生成 `Validate` 方法，并引入 `Validator` 中间件即可：

```go
httpSrv := http.NewServer(
    http.Address(":8000"),
    http.Middleware(
        validate.Validator(),
    ))

grpcSrv := grpc.NewServer(
    grpc.Address(":9000"),
    grpc.Middleware(
        validate.Validator(),
    ))
```

### 迁移到 protovalidate

随着 PGV 进入维护状态，我们应该尽可能迁移到 `protovalidate`。为此，我提交了 [PR#3498](https://github.com/go-kratos/kratos/pull/3498)，并成功合入。该 PR 在 `contrib` 目录下添加了一个基于 `protovalidate` 的中间件实现，并兼容了历史上生成的 `Validate` 方法，以减少迁移成本。

其使用方式与 PGV 的中间件相似，区别在于，使用 `protovalidate` 时，不再需要生成 `Validate` 方法，将于运行时自动读取 `proto.Message` 对象的反射信息，进而创建校验逻辑。

## 总结与建议

PGV 和 protovalidate 都是强大的 ProtoBuf 验证工具，它们帮助开发者简化数据验证逻辑，提高代码质量。

- **PGV**：成熟的验证工具，适合简单的验证需求，但已进入维护状态
- **protovalidate**：PGV 的继任者，提供了更丰富的功能和更好的跨语言一致性

对于新项目，建议直接使用 protovalidate；对于已有项目，可以考虑通过 Kratos 的兼容性中间件进行渐进式迁移。

无论选择哪个工具，都可以在 Kratos 框架中方便地集成和使用，提高开发效率和代码质量。

