---
title: "基于 HTTP 的 Cargo Registry提案"
date: 2022-01-26T17:36:28Z
draft: true
authors: [ 'DCjanus' ]
tags: ['Rust']
---

目前（2022年1月）Rust 官方的集中包管理依赖[一个 Git 仓库](https://github.com/rust-lang/crates.io-index)存储与分发索引信息，其相关格式可以在这里(https://doc.rust-lang.org/cargo/reference/registries.html#index-format)进一步了解。

