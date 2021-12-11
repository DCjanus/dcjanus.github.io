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

{{< figure src="https://image-demo.img-cn-hangzhou.aliyuncs.com/example.jpg@300w_300h.webp" title="https://image-demo.img-cn-hangzhou.aliyuncs.com/example.jpg@300w_300h.webp" >}}

其中 `@` 符号前的是[原始图片地址](https://image-demo.img-cn-hangzhou.aliyuncs.com/example.jpg)，其后`300w_300h.webp`为缩略图参数，表示将原图等比例缩放为一个宽不大于300、高不大于300的 webp 图片。

### 2. 请求参数

以阿里云新版图片处理服务为例，其选择在原始图片 URL 后添加特定的 Query String 指定处理参数，如与上面缩略图参数等价的请求：

{{< figure src="https://image-demo.oss-cn-hangzhou.aliyuncs.com/example.jpg?x-oss-process=image/resize,w_300/format,webp" title="https://image-demo.oss-cn-hangzhou.aliyuncs.com/example.jpg?x-oss-process=image/resize,w_300/format,webp" >}}

### 3. 多级路径

<!-- 用 / 分隔，可能是为了方便 CDN 缓存清理 -->

<!-- 自由组合参数 / 预设计模板字符串 -->

<!-- 缓存 or 预存 -->

<!-- 在线处理 or 预热 -->

<!-- 多级缓存设计 -->

<!-- 热点图限制与调度 -->

<!-- 参数设计: 过程化 / 场景化 -->