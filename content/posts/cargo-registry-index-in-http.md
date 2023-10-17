---
title: "Cargo Registry 稀疏索引的一些介绍"
date: 2022-01-26T17:36:28Z
authors: ['DCjanus']
tags: ['Rust', 'Cargo']
---

Rust 的官方包管理系统依赖一个 GitHub 上的 Git 仓库[^crates.io-index]管理索引信息，其相关格式也有较为详细的定义[^registry-index-format]。

随着 crates.io-index 体积的不断膨胀，现有的分发方案逐渐表现出了一些弊端，Rust 社区开发者也提出了名为稀疏索引（Spare Index）的 RFC[^RFC-2789]，用于优化相关场景。春节放假无聊，简单介绍一下前因后果，也希望有兴趣有能力的人可以推动其落地与发展。

<!-- more -->

# 问题背景

crates.io 上每个 crate 的每次发布，最终都会触发一次对 crates.io-index 的 commit 操作，将新版本 crate 的信息记录在对应的索引文件中，开发者使用 Cargo 更新本地索引时，实际上就是在从远端拉取该 Git 仓库的变动到本地。

Cargo 支持两种方式操纵本地 Git 仓库：libgit2 和 Git 命令行。相比较于 Git，libgit2 有很多功能上的缺失。与本文相关的是，libgit2 目前（2022年1月）仍不支持 shallow clone 和 spare-checkout。

对于 Registry Index 场景来说，提交历史没有太多价值，但由于没有 shallow clone 的支持，随着提交历史的不断积累，越来越多的网络流量浪费在了无意义的数据之上[^shallow-clone-test]。crates.io 有定时任务执行 squash[^crates.io-auto-squash-pr]，一定程度上可以缓解这个问题。

除了提交历史导致的流量浪费外，对于 CI 等一次性构建场景，完整的索引也是不必要的：即使你的项目仅依赖了几个 crate，你也需要下载包含所有 crates 的索引，但事实上每个 crate 的索引信息都位于独立的文件中，理论上只需要其中的一个子集即可完成构建需求。Git 于 2.25.0 版本支持了`稀疏检出`特性，且 GitHub 也有相关文章介绍[^GitHub-blog-about-spare-checkout]，可以 clone 一个 Git 仓库的特定子树。但一方面，该功能较新，兼容性方面不是很友好，另一方面，不管是 shallow clone 还是 spare-checkout，受限于 Git 模型的设计，往往是需要在线计算的过程，事实上从 Ruby 社区的经验来看，GitHub 会对服务端 CPU 开销进行限制[^GitHub-limit-cpu-usage-on-large-repo]。

# 一些可能的方案

在实际讨论 RFC 描述内容之前，需要了解我们对这些方案需要从哪些角度考量。长期以来，基于 Git 的索引方案，存在这样一些缺陷：

+ 有不必要的网络流量开销，尤其是对 CI 之类一次性的场景
+ 对慢速网络环境不友好（如某些有特殊网络政策的国家）
+ 对企业内部搭建镜像和 registry 不友好[^git-based-registry-not-friendly]
+ 运行成本与索引规模几乎线性相关甚至更糟

为了应对以上问题，以下是一些讨论过程中提出的备选方案

## 1. 独立查询服务

根据依赖列表和索引目录生成完整依赖树的过程，可以很轻松的从本地目录查询转换为一次 HTTP 接口调用，脱离 Git 协议的桎梏，更灵活的实现需求，但显而易见的，这个依赖树的生成逻辑并不轻量，难以复用 CDN、S3 之类的基础设施，且对于这样重要的服务来说，动态 API 的可靠性显著低于一个简单的静态文件服务。

## 2. Git Dumb HTTP Protocol

Git 规定了 Dumb HTTP 协议，基于它，可以通过一个简单的静态文件服务器（比如 NGINX）搭建 Git 镜像，简化企业内部构建 Rust 相关基础设施的成本。但由于 Git 会在某些条件下将多个离散 Git 对象打包成单个大文件，预计 Dumb HTTP 协议的方案仍然会消耗不必要的网络流量。

## 3. raw.github.com

GitHub 提供了大量的 API 与 Git 仓库交互，并且可以直接根据特定规则获取特定文件内容，但不愿意透露姓名的社区群众 ~~DCjanus~~ 指出，大量调用 raw.github.com 对 GitHub 并不友好[^raw-github.com-not-cheap]。另外，这个方案最大的问题是，对于非 GitHub 托管的 index，将难以使用。所以可预见的，索引文件需要在其他地方进行托管。

## 4. ZSync

ZSync 算法实现上主要针对大文件，对于 crates 索引这样的场景，需要对索引文件布局做较大改动，不在当前阶段讨论范围内。

# 初步方案

目前处于早期探索阶段，主要为了积累一些测试数据，而不是为了达成一个最优方案：保持现有索引文件布局不变，客户端直接通过若干次 HTTP 请求实现相关逻辑。根据作者的测试，只要并发开得多，就可以获得跟不比 Git 方案差很多的速度，并且大大节约网络带宽，且可以更好的应对将来索引越发膨胀的问题。

由于 CDN 缓存的存在，相比 Git 方案，多次 HTTP 请求之间，难以保证它们获取到的是索引目录的同一快照。可能会导致 resolve 到某个 crate 的旧版本，或找不到特定 crate 版本。

前者是相对安全的，定期 update 的项目最终会获取到新版本，通过主动的 CDN 缓存刷新可以加速这个过程；

后者则相对棘手，要求客户端有能力探测这类问题，意识到自己可能请求了一个较旧版本的缓存，进而通过诸如添加时间戳参数之类的方式 bypass CDN 缓存。（事实上不同 CDN 缓存处理方式不同，这并不是一个可以简单推广的方案）

# 当前状态

目前 RFC 已经被接受，并有了一个初步实现: <https://github.com/rust-lang/cargo/pull/8890>，但缺乏相关人士推动，PR 迟迟没有合并，相关讨论也已经停滞良久。

:broken_heart: :broken_heart: :broken_heart:

[^crates.io-index]: https://github.com/rust-lang/crates.io-index
[^registry-index-format]: https://doc.rust-lang.org/cargo/reference/registries.html#index-format
[^RFC-2789]: https://github.com/rust-lang/rfcs/blob/master/text/2789-sparse-index.md
[^crates.io-auto-squash-pr]: https://github.com/rust-lang/crates.io/pull/3592
[^shallow-clone-test]: 以落笔时的最新commit (`af2d61cc9922ea9c67479718b2014a621e43e9d0`) 为例，直接 fetch，流量消耗 `78.45 MiB`；使用 shallow clone，则仅有 `45.18 MiB`。
[^GitHub-blog-about-spare-checkout]: https://github.blog/2020-01-17-bring-your-monorepo-down-to-size-with-sparse-checkout
[^GitHub-limit-cpu-usage-on-large-repo]: https://blog.cocoapods.org/Master-Spec-Repo-Rate-Limiting-Post-Mortem/
[^git-based-registry-not-friendly]: https://github.com/rust-lang/rfcs/pull/2789#issuecomment-556526112
[^raw-github.com-not-cheap]: https://github.com/rust-lang/rfcs/pull/2789#issuecomment-569386851