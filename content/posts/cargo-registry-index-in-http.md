---
title: "Cargo Registry Spare Index（稀疏索引）"
date: 2022-01-26T17:36:28Z
draft: true
authors: [ 'DCjanus' ]
tags: ['Rust']
---

Rust 的官方包管理系统依赖一个 GitHub 上的 Git 仓库[^crates.io-index]管理索引信息，其相关格式也有较为详细的定义[^registry-index-format]。

随着 crates.io-index 体积的不断膨胀，现有的分发方案逐渐表现出了一些弊端，Rust 社区开发者也提出了名为稀疏索引（Spare Index）的 RFC[^RFC-2789]，用于优化相关场景。春节放假无聊，简单介绍一下前因后果，也希望有兴趣有能力的人可以推动其落地与发展。

<!-- more -->

# 背景

crates.io 上每个 crate 的每次发布，最终都会触发一次对 crates.io-index 的 commit 操作，将新版本 crate 的信息记录在对应的索引文件中，开发者使用 Cargo 更新本地索引时，实际上就是在从远端拉取该 Git 仓库的变动到本地。

Cargo 支持两种方式操纵本地 Git 仓库：通过 git2 crate 间接调用 libgit2 和直接调用 Git 可执行文件。相比较于 Git，libgit2 有很多功能上的缺失。与本文相关的是，libgit2 目前（2022年1月）仍不支持 shallow clone。

对于 Registry Index 场景来说，提交历史没有太多价值，但由于没有 shallow clone 的支持，随着提交历史的不断积累，越来越多的网络流量浪费在了无意义的数据之上[^shallow-clone-test]。crates.io 有定时任务执行 squash[^crates.io-auto-squash-pr]，一定程度上可以缓解这个问题。

除了提交历史导致的流量浪费外，对于 CI 等一次性构建场景，完整的索引也是不必要的：即使你的项目仅依赖了几个 crate，你也需要下载包含所有 crates 的索引，但事实上每个 crate 的索引信息都位于独立的文件中，理论上只需要其中的一个子集即可完成构建需求。

<!-- TODO -->

[^crates.io-index]: https://github.com/rust-lang/crates.io-index
[^registry-index-format]: https://doc.rust-lang.org/cargo/reference/registries.html#index-format
[^RFC-2789]: https://github.com/rust-lang/rfcs/blob/master/text/2789-sparse-index.md
[^crates.io-auto-squash-pr]: https://github.com/rust-lang/crates.io/pull/3592
[^shallow-clone-test]: 以落笔时的最新commit (`af2d61cc9922ea9c67479718b2014a621e43e9d0`) 为例，直接 fetch，流量消耗 `78.45 MiB`；使用 shallow clone，则仅有 `45.18 MiB`。
