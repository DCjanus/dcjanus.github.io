---
title: "统一图片服务设计"
date: 2021-12-11T23:42:56+08:00
draft: true
author: DCjanus
description: "描述了统一图片服务的一些设计因素"
---

常见公有云都提供 OSS 和与之配套的在线图片处理服务，只要在 URL 上做一些小的修改，就可以获得多种图片处理功能，如尺寸缩略、格式转换、高斯模糊、内容裁剪等功能。但当尝试自建服务时，就有了一些需要额外考虑的点。

<!--more-->

# 业务设计

## 调用形式

图片处理服务的调用，无外乎指定要被处理的图片与应该应用其上的操作，一般通过 URL 的编辑实现类似功能，但不同的调用形式之间也存在一些细微的区别。

### 1. 分隔符

以阿里云旧版图片处理服务为例，其设计上使用 `@` 分隔图片地址和处理参数，如:

{{< image src="https://image-demo.img-cn-hangzhou.aliyuncs.com/example.jpg@300w_300h.webp" caption="https://image-demo.img-cn-hangzhou.aliyuncs.com/example.jpg@300w_300h.webp" >}}

其中 `@` 符号前的是[原始图片地址](https://image-demo.img-cn-hangzhou.aliyuncs.com/example.jpg)，其后`300w_300h.webp`为缩略图参数，表示将原图等比例缩放为一个宽不大于300、高不大于300的 webp 图片。

### 2. 请求参数

以阿里云新版图片处理服务为例，其选择在原始图片 URL 后添加特定的 Query String 指定处理参数，如与上面缩略图参数等价的请求：

{{< image src="https://image-demo.oss-cn-hangzhou.aliyuncs.com/example.jpg?x-oss-process=image/resize,w_300/format,webp" caption="https://image-demo.oss-cn-hangzhou.aliyuncs.com/example.jpg?x-oss-process=image/resize,w_300/format,webp" >}}

这里的缩略参数是`image/resize,w_300/format,webp`，表达的含义与上面相同。

## 区别总结

选择使用 Query String，要注意 CDN 和 内部缓存集群的缓存 Key 配置，要将请求 Key 作为缓存 Key 的一部分。

选择使用 `@` 符号分隔，往往意味着原始文件名中的 `@` 符号可能造成一些非预期的现象，如 `a.jpg@2x`、`a.jpg@3x` 是常见的设计资源命名形式，对于使用 `@` 符号分隔的服务，则有可能被认为是错误的图片处理参数。这类场景往往将普通文件访问域名和图片处理域名区分开，如访问 `example.com/a.jpg@100w` 表示访问存储系统中名为 `a.jpg@100w` 的文件，访问`image.example.com/a.jpg@100w` 则表示请求 `example.com/a.jpg` 并进行处理。

如果你使用功能相对较弱的 CDN，在使用 `@` 符号分隔时，也要考虑这样的场景：`example.com/a.jpg` 因为涉黄涉暴，必须紧急删除消除影响，你删除了这个文件，并刷新了对应的 CDN 缓存。但因为之前被人访问过，所以它的缩略图 `example.com/a.jpg@100w` 和 `example.com/a.jpg@200w` 仍然会在 CDN 被人访问，由于内部实现细节的影响，部分 CDN 厂商只提供基于 `/` 分隔的前缀删除，这意味着你无法简单清理 `example.com/a.jpg@100w` 和 `example.com/a.jpg@200w` 的缓存。部分 CDN 厂商可能提供基于阉割版正则的批量清理逻辑，可以覆盖这类场景。

## 调用限制

<!-- 自由组合参数 / 预设计模板字符串 -->

<!-- 缓存 or 预存 -->

<!-- 在线处理 or 预热 -->

<!-- 多级缓存设计 -->

<!-- 热点图限制与调度 -->

<!-- 参数设计: 过程化 / 场景化 -->