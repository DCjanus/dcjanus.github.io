---
title: "从滴答清单 MCP 说起：OAuth Dynamic Client Registration"
date: 2026-05-06T00:52:00+08:00
draft: true
authors: ['DCjanus']
tags: ['OAuth', 'MCP', 'TickTick', 'Dida365']
---

最近看滴答清单的 MCP 支持时，我注意到它的 OAuth metadata 里已经暴露了 `registration_endpoint`。这意味着客户端不一定要提前在开发者后台注册 OAuth App，而是可以通过标准接口动态完成注册。这就是 OAuth 2.0 里的 Dynamic Client Registration。

这个变化对我来说比较有现实感。之前为了让 Codex 能操作滴答清单，我写过一个 `ticktick-cli` skill。当时滴答清单虽然已经有 Open API，但整体体验比较基础：需要自己去开发者后台注册 OAuth App，拿到 `client_id` / `client_secret`，然后再处理 OAuth 登录流程。

当时的实现方式，是把授权流程单独拆出来。额外写一个 Worker，专门负责 OAuth 登录和 token 获取；本地 CLI 只负责拿 token 调用滴答清单 API。这套方案能用，但代价也很明显：为了一个个人脚本或者本地 agent，需要先完成“注册开发者应用”这一步。DCR 关注的正是这个步骤能不能被标准化和自动化。

<!-- more -->

## 以前的问题

传统 OAuth 通常假设 Client 是提前注册好的。接入 GitHub、Google、滴答清单这类服务时，开发者一般需要先去后台创建应用，填写应用名、回调地址、权限范围，再拿到 `client_id`。有些平台还会发放 `client_secret`。之后程序才能把用户带到授权页面，让用户确认授权。

这个模型适合固定的 Web 应用。比如某个 SaaS 产品接入 Google Calendar，它有固定域名、固定回调地址、固定开发团队。提前注册一个 OAuth App 不是什么问题，甚至是必要的治理手段。

这个模型不太适合 MCP 这类动态连接场景。MCP client 可能是 Claude、Cursor、Codex、ChatGPT，也可能是用户自己跑在本机的工具。MCP server 也可能是任意服务暴露出来的一个 endpoint。两边不一定提前认识，很多时候是运行时才建立连接。

手工注册会显著抬高 MCP 的使用门槛。如果每接入一个 OAuth 保护的 MCP server，都要求用户先去对应服务的开发者后台注册应用，再把 `client_id` 填回 MCP client，这就不是面向普通用户的集成体验了。很多用户只是想让 AI 帮自己读写待办事项，并不是想成为滴答清单的第三方应用开发者。

## Dynamic Client Registration 是什么

Dynamic Client Registration 的核心作用，是把 OAuth Client 注册变成标准 API。它通常简称 DCR，由 [RFC 7591](https://www.rfc-editor.org/rfc/rfc7591) 定义。传统流程里需要人在后台填写的 client metadata，在 DCR 中可以由程序提交给 Authorization Server。

一个 DCR 请求本质上是在提交 client metadata。Client 可以向注册接口提交应用名、回调地址、授权类型、响应类型、token endpoint 认证方式等信息。例如：

```json
{
  "client_name": "Example MCP Client",
  "redirect_uris": ["http://127.0.0.1:12345/callback"],
  "grant_types": ["authorization_code"],
  "response_types": ["code"],
  "token_endpoint_auth_method": "none"
}
```

Authorization Server 会根据自己的策略校验这些 metadata。如果接受注册，它会返回一个 `client_id`；在某些 confidential client 场景里，也可能返回 `client_secret`。之后这个 Client 就可以像普通 OAuth 应用一样，继续走 authorization code + PKCE 等授权流程。

DCR 解决的是“谁来注册 Client”的问题。它不是用户授权，也不是绕过 OAuth。它只是发生在用户授权之前，负责让 Client 动态拿到一个授权服务器认可的 `client_id`。

DCR 通常会和 Authorization Server Metadata 一起使用。[RFC 8414](https://www.rfc-editor.org/rfc/rfc8414) 定义了授权服务器如何暴露自己的元信息。Client 可以先访问类似这样的 well-known 地址：

- [https://ticktick.com/.well-known/oauth-authorization-server](https://ticktick.com/.well-known/oauth-authorization-server)
- [https://dida365.com/.well-known/oauth-authorization-server](https://dida365.com/.well-known/oauth-authorization-server)

这些 metadata 会告诉 Client 授权地址在哪里、换 token 的地址在哪里、动态注册地址在哪里，以及服务器支持哪些 grant type 和 PKCE 方法。

TickTick / 滴答清单现在已经暴露了动态注册入口。我看到它们的 metadata 中包含了 `registration_endpoint`，例如：

- TickTick: `https://api.ticktick.com/oauth/register`
- 滴答清单: `https://api.dida365.com/oauth/register`

这些 metadata 也声明了 `authorization_code`、`S256` PKCE，以及 `token_endpoint_auth_method` 中的 `none`。这些信息组合在一起，基本对应的是“运行时发现授权服务器，动态注册 public client，然后走授权码流程”。

## 为什么说它看起来是为 MCP 准备的

严格来说，DCR 不是 MCP 发明的。RFC 7591 是 2015 年的规范，比 MCP 早很多。它原本解决的是 OAuth client 无法预先静态登记的问题。

MCP 让这个老机制重新变得重要。MCP 的典型使用方式不是“一个固定服务提前接入另一个固定服务”，而是“用户手里的 AI client 临时连接很多工具”。这意味着 OAuth 的 client 关系很难提前静态建立：

- 服务提供方不知道未来会有哪些 MCP client 来接入。
- MCP client 也不可能提前为每个服务申请好 OAuth App。
- 用户不应该被迫理解开发者后台、redirect URI、client secret 这些细节。
- 本地 MCP client 往往是 public client，本来就不适合长期保存 `client_secret`。

MCP 授权规范也明确处理了这个问题。Authorization Server Metadata 负责让客户端自动发现 OAuth 端点；Dynamic Client Registration 负责让客户端在没有人工介入的情况下拿到 `client_id`。在 [2025-06-18 版本](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)里，DCR 还是 MCP client 和 authorization server 的 SHOULD。较新的 [draft](https://modelcontextprotocol.io/specification/draft/basic/authorization) 开始把 Client ID Metadata Documents 放到更优先的位置，并把 DCR 作为 fallback / backward compatibility 方案。

这个变化说明 MCP 授权仍在演进，但核心问题没有变。Client 和 server 之间通常没有预先建立好的 OAuth 注册关系。对传统 Open API 来说，让开发者手工注册 OAuth App 是可以接受的；但对 MCP 来说，如果还停留在这个模式，通用 MCP client 很容易卡在第一步。

滴答清单补上 DCR，很可能就是为了适配这个使用模型。它不只是给传统开发者提供一个 API，而是要让通用 MCP client 能够自动完成发现、注册和授权这条链路。

## 它解决了什么问题

DCR 首先降低了接入门槛。以前我为了写一个本地 skill，需要注册 OAuth App，还要自己写 Worker 处理登录。DCR 之后，理论上 MCP client 可以直接读取 metadata，动态注册自己，再把用户带到授权页面。用户看到的应该是“连接滴答清单”，而不是“请先创建一个开发者应用”。

DCR 也让服务更适合开放生态。如果每个 client 都要人工审核、手工注册，那么服务提供方只能支持少量固定集成。DCR 允许更多 client 以标准方式接入，尤其适合 MCP 这种客户端和服务端都在快速变化的生态。

DCR 还把很多集成约定标准化了。以前大家各写各的 OAuth 文档：授权地址是什么、token 地址是什么、redirect URI 怎么填、public client 能不能没有 secret。DCR 配合 Authorization Server Metadata 后，这些信息可以由机器读取，而不是靠用户复制粘贴文档。

## 挑战也很明显

DCR 最大的问题，是注册门槛降低了，但风险没有消失。注册接口如果完全开放，任何人都可以批量创建 client。攻击者可以注册一个看起来很像官方应用的 `client_name`，诱导用户授权；也可以用大量注册请求制造垃圾数据和运营压力。

redirect URI 校验是另一个关键点。传统 OAuth App 通常会在后台固定 redirect URI；DCR 场景里，这些 URI 是 client 注册时动态提交的。如果校验太宽，可能引入 open redirect、恶意 scheme、localhost callback 混淆等问题。

Client 身份的可信度也需要单独看待。DCR 能证明“这个 `client_id` 是授权服务器发的”，但不能证明“这个 client 是可信软件”。尤其是 public client 没有可靠的 secret，`client_id` 更多只是协议流程里的标识，不应该被当成强身份认证。

生产系统支持 DCR 时，需要配套明确的安全策略。至少应考虑这些方面：

- 限制 metadata 字段，尤其是 `redirect_uris`、`client_name`、logo 等用户可见内容。
- 对注册接口做限流、风控或初始访问令牌控制。
- 明确区分 public client 和 confidential client。
- 要求 PKCE，尤其是本地客户端和 agent 场景。
- 在授权页面上清楚展示风险，而不是把动态注册的 client 包装成“已认证官方应用”。

DCR 解决的是 onboarding 和互操作问题，不是信任问题。它听起来像是“自动化注册”，但不是一个可以无脑打开的开关。注册越自动化，授权服务器越需要在校验、展示、限流和审计上做清楚边界。

## 小结

这次关注 Dynamic Client Registration，起点是一个很具体的工程问题。以前为了让 AI 调用滴答清单，我需要自己注册 OAuth App，并额外写 Worker 处理登录；现在滴答清单为了 MCP，把 OAuth metadata 和动态注册补了起来。

DCR 本身并不复杂。它只是让 OAuth client 可以通过 API 注册自己，并拿到 `client_id`。但它刚好补上了 MCP 授权链路里很关键的一环：通用 AI client 不可能为每个服务提前手工注册应用。

它的价值在于自动化接入和标准化发现。它的挑战则在于安全边界、client 可信度和授权页面的用户认知。对于 MCP 生态来说，这会是一个很常见、也容易被低估的基础设施细节。

## 参考资料

- [RFC 7591: OAuth 2.0 Dynamic Client Registration Protocol](https://www.rfc-editor.org/rfc/rfc7591)
- [RFC 7592: OAuth 2.0 Dynamic Client Registration Management Protocol](https://www.rfc-editor.org/rfc/rfc7592)
- [RFC 8414: OAuth 2.0 Authorization Server Metadata](https://www.rfc-editor.org/rfc/rfc8414)
- [MCP Authorization](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)
- [MCP Authorization Draft](https://modelcontextprotocol.io/specification/draft/basic/authorization)
