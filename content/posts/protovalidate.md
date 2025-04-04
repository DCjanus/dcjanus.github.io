---
title: "protoc-gen-validate (PGV) 和 protovalidate"
date: 2025-04-04T23:58:52+08:00
authors: ['DCjanus']
tags: ['golang', 'protobuf', '微服务']
---

最近一年因为机缘巧合，工作中比较多的使用 [Kratos](https://github.com/go-kratos/kratos) 框架开发，该框架围绕 ProtoBuf 和 DDD 设计，且侵入性低，方便根据业务需求进行裁剪。

在官方模板中，开发者可以通过 ProtoBuf 定义服务接口，进而生成 OpenAPI 文档、客户端代码、服务端代码等；除此之外，官方文档中还介绍了使用 `protoc-gen-validate` 插件生成数据验证代码，进而简化数据验证逻辑。

## 什么是 PGV

`protoc-gen-validate` (PGV) 原是 Envoy 团队开发的一款 protoc 插件，可以根据 Proto 文件中定义的校验规则，生成对应的校验代码，方便调用。

以下是简单的使用示例：

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

## PGV 的工作原理

PGV 的工作原理相对简单：

1. 在 Proto 文件中定义验证规则
2. 使用 PGV 插件生成验证代码
3. 在服务端或客户端调用生成的验证方法

生成的验证代码通常包含 `Validate()` 和 `ValidateAll()` 方法，前者在遇到第一个错误时返回，后者会收集所有错误并一次性返回。

## PGV 的局限性

虽然 PGV 提供了强大的验证功能，但它也有一些局限性：

1. 只能处理简单的验证规则，复杂的业务逻辑验证需要自行实现
2. 验证规则与 Proto 定义耦合，修改验证规则需要重新生成代码
3. 多语言一致性存在问题，不同语言生成的验证逻辑可能存在细微差异

## protovalidate 的诞生

为了解决 PGV 的一些局限性，buf 团队开发了 `protovalidate`，它是 PGV 的继任者，提供了更灵活、更强大的验证功能。

## protovalidate 的主要改进

相比 PGV，protovalidate 有以下主要改进：

1. **更丰富的验证规则**：支持更多的数据类型和验证规则
2. **更灵活的验证方式**：支持通过 CEL 自定义验证函数和条件验证
3. **更好的错误处理**：提供更详细的错误信息和更好的错误处理机制
4. **更好的跨语言一致性**：基于 CEL 定义语言无关的验证规则，简化多语言实现

## 如何在 Kratos 中使用

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

但是随着 PGV 进入维护状态，我们应该尽可能迁移到 `protovalidate` 上，为此，我于早先时候提交了 [PR#3498](https://github.com/go-kratos/kratos/pull/3498)，并成功合入，该 PR 在 `contrib` 目录下添加了一个基于 `protovalidate` 的中间件实现，并兼容了历史上生成的 `Validate` 方法，以减少迁移成本。

其使用方式与 PGV 的中间件相似，区别在于，使用 `protovalidate` 时，不再需要生成 `Validate` 方法，将于运行时自动读取 proto.Message 对象的 reflect 信息，进而创建校验逻辑。

