---
title: "一些零碎知识"
date: 2022-01-31T21:29:55+08:00
draft: false
authors: ['DCjanus']
tags: []
description: "平时有很多零碎的知识点，写起来没几句，重新摸索一遍可能很花时间，在这里简单记录一下，方便自己查阅。"
---

<!--more-->
---

在 Windows 上使用 CLion 直接打开 WSL2 文件系统内的 Rust 项目，建立索引的速度慢到令人发指，并且有各种小问题。一开始以为是 WSL2 跨文件系统访问的性能问题，但即使已经保证代码和工具链都在 WSL 内，也还是没能有所改善。后来发现是需要配置 run target 为 WSL 才可以。

---

目前（2022年6月）WSL2 不能直接安装 ArchLinux，可以用 [Distrod](https://github.com/nullpo-head/wsl-distrod) 安装，甚至还能使用 systemd，真香。

---

常见的一致性哈希算法存在一定的不均匀性，可以通过`影子节点`的方式缓解，但与此同时也会降低性能。谷歌 2014 年发布的跳跃一致性 Hash 算法可以解决不均匀的问题，但原始算法又无法支持非尾部节点增删时的少迁移性。

相关文章：<https://writings.sh/post/consistent-hashing-algorithms-part-1-the-problem-and-the-concept>

---

NGINX 默认使用`单 listen socket, 多 worker process` 的模型，但是部分情况下，EPOLL 会表现出 `LIFO` 的特性，这可能会导致 worker 进程负载不均衡。

详细信息：<https://blog.cloudflare.com/the-sad-state-of-linux-socket-balancing>

---

想对历史 commit 做一些小修改，又不希望多加一个 commit，可以通过以下命令改写：
```bash
git add -u
git commit --fixup $TARGET_COMMIT
export EDITOR=true # 可选，避免跳出交互式窗口
git rebase -i --autostash --autosquash $TARGET_COMMIT
```

相关解释：<https://ttys3.dev/post/git-fixup-amend-for-any-older-commits-quickly/>

---
ImageMagick 部分操作需要产生随机数，默认会在支持 mkstemp 的环境，将 mkstemp 生成的文件名作为随机数熵的一部分，对于服务端常态运行的场景，会产生大量文件系统读写，有一定的性能影响，可以通过条件编译排除这个特性。

相关讨论：<https://github.com/ImageMagick/ImageMagick/discussions/2783>

---

相比 Go 等语言，Rust 编译速度很慢，对于本地开发，可以复用编译缓存，一定程度上缓解这个问题； 但是对于 CI/CD ，一般都是在独立环境中运行，往往不会包含编译缓存。

如果你的 CI/CD Job 在 Docker 环境执行，可以通过 [cargo-chef](https://github.com/LukeMathWalker/cargo-chef) 烘焙依赖项缓存到 Docker 镜像层中，减少构建时间，大概流程如下。