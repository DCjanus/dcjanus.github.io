---
title: "Linux 内核版本号过大导致 TiKV 的一次 Panic"
date: 2022-12-17T23:19:25+08:00
authors: ['DCjanus']
tags: ['Rust']
---

## TLDR

Linux 内核版本号曾被认为可以用三个 8bit 无符号整数表示，但后来这个约定被打破。TiKV 间接使用的库在解析内核版本号时，没有考虑到这一点，导致 panic。

<!--more-->

-----

## 前因

某年某月，因为某些工作的需求，由我所在的团队提供服务器，DBA 团队帮忙部署一套 TiDB。部署过程中，DBA 团队告知，因公司内部维护的内核版本问题，TiKV 一启动就会 panic，无法正常交付。当时受限于精力，没有深究。

过了几个月，某位同事用 Rust 写的遗留服务遭遇突发流量，我在公司内部 k8s 平台上操作扩容，发现部分服务进程启动后立即 panic。增加 `RUST_BACKTRACE=1`的环境变量后成功复现，根据堆栈信息成功定位到根因，事后复盘发现与之前部署 TiKV 时遇到的问题是同一个问题。

## 背景

Linux 内核版本号由三个十进制数字组成，形如 `x.y.z`，如本文写作时，本人所用 ArchLinux 的内核版本号为 `6.0.12`。这三个数字分别代表了主版本号、次版本号和补丁版本号。其中，主次版本号的组合即一个内核的大版本，如 `5.0`、`5.1`、`5.2` 等，一般认为大版本内的更新应尽量避免引入不兼容的改动。部分内核大版本会得到开发者的长期维护，如`5.4`、`4.19`等，每当有安全更新被合并到这些 LTS 版本的代码树中，其补丁版本号会递增，如`4.19.233` -> `4.19.234`。

对于一些相对底层的开发者，如内核模块、驱动开发者，他们可能会在自己的代码中使用 `LINUX_VERSION_CODE` 宏来判断当前内核版本，即将三段式的版本号编码为单个无符号数，以便于方便的对比。早期在 `/usr/include/linux/version.h` 的定义如下

```c
#define LINUX_VERSION_CODE 263168
#define KERNEL_VERSION(a,b,c) (((a) << 16) + ((b) << 8) + (c))
```

## 问题

显而易见的，在 `LINUX_VERSION_CODE` 的实现下，版本号中每个部分的最大值为 255。所以长期以来，大家都认为 Linux 内核版本号可以用三个 8 bit 的无符号整数表示。

但 2021 年，这件事有所改变。2021 年 2 月 4 日，`Jari Ruusu` 在邮件组中向 `4.9` 和 `4.4` 版本的维护者，`Greg Kroah-Hartman`，发送了[一封邮件](https://lore.kernel.org/lkml/7pR0YCctzN9phpuEChlL7_SS6auHOM80bZBcGBTZPuMkc6XjKw7HUXf9vZUPi-IaV2gTtsRVXgywQbja8xpzjGRDGWJsVYSGQN5sNuX1yaQ=@protonmail.com/T/)，询问 `4.9.255` 和 `4.9.255` 后的版本变更，是否要继续递增 patch 版本号。最终，`Greg Kroah-Hartman` 选择发布了 `4.9.256` 和 `4.4.256`。

TiKV 团队维护了一个 Rust 的 Prometheus 库，用于对外暴露指标。其间接使用了 [procfs](https://github.com/eminence/procfs) 获取主机信息。在该库中，有一个结构体用于描述内核版本号，描述为三个 8 bit 的无符号整数，其定义如下。

```rust
#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub struct Version {
    pub major: u8,
    pub minor: u8,
    pub patch: u8,
}
```

该结构体提供了[一个方法](https://github.com/eminence/procfs/blob/86d71e5235a36fb0718028d58662863d88a1f158/src/sys/kernel/mod.rs#L47-L67)，从 `/proc/sys/kernel/osrelease` 中读取形如 `3.16.0-6-amd64` 的内核版本号并解析。

解析整数部分使用的是 Rust 标准库提供的代码，在解析失败时，如数值超出取值范围，会返回错误。`procfs` 提供了一个全局变量对外暴露当前版本号，在解析出错时会直接 panic。所有间接调用这段代码的项目，运行在内核版本号大于 255 的主机上，都会 panic。

```rust
static ref KERNEL: KernelVersion = {
    KernelVersion::current().unwrap()
};
```

## 修复

当时我们的生产环境发行版基于 Debian 9，但内核是我们内部维护的版本，其补丁版本号大于 256，导致 TiKV 和我们的 Rust 服务发生 panic。暂时的修复方案是将主机内核版本临时修改为一个低于 255 的值。

后续 `procfs v0.10.0` 修复了这个问题，我给 `rust-prometheus` 提了个 [issue](https://github.com/tikv/rust-prometheus/issues/414)，鼓励维护者发布包含修复的新版本，并更新了我们内部服务的依赖。

TiKV 目前也已经完成了[基础库的升级](https://github.com/tikv/tikv/blob/416f7b7504a2766edb2c7b7b4a5b8c6e24485440/Cargo.lock#L4037-L4052)，修复了这个问题。

## 附录

现在(2022年)，如果你使用一些比较追新的发行版，如 ArchLinux 中，查看 `/usr/include/linux/version.h`，会发现其内容如下。
    
```c
#define LINUX_VERSION_CODE 332303
#define KERNEL_VERSION(a,b,c) (((a) << 16) + ((b) << 8) + ((c) > 255 ? 255 : (c)))
#define LINUX_VERSION_MAJOR 5
#define LINUX_VERSION_PATCHLEVEL 18
#define LINUX_VERSION_SUBLEVEL 15
```

即 `LINUX_VERSION_CODE` 仍然保留，在补丁版本大于 255 时，`LINUX_VERSION_CODE` 的值将不会改变。对于较新的代码，可以使用 `LINUX_VERSION_MAJOR` 等宏常量来获取更准确的内核版本号。

## 参考
+ <https://lwn.net/Articles/845120>