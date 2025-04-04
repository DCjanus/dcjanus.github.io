---
title: “protoc-gen-validate (PGV) 和 protovalidate"
date: 2025-04-04T23:58:52+08:00
authors: ['DCjanus']
tags: ['golang', 'protobuf', '微服务']
---

最近一年因为机缘巧合，工作中比较多的使用 [Kratos](https://github.com/go-kratos/kratos) 框架开发，该框架围绕 ProtoBuf 和 DDD 设计，且侵入性低，方便根据业务需求进行裁剪。

在官方模板中，开发者可以通过 ProtoBuf 定义服务接口，进而生成 OpenAPI 文档、客户端代码、服务端代码等；除此之外，官方文档中还介绍了使用 `protoc-gen-validate` 插件生成数据验证代码，进而简化数据验证逻辑。

## 什么是 PGV

`protoc-gen-validate` 原是 Envoy 团队开发的一款 protoc 插件，可以根据 Proto 文件中定义的校验规则，生成对应的校验代码，方便调用。

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




