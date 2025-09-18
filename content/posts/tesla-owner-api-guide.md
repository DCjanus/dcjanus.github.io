---
title: "Tesla Owner API 实践记录"
date: 2025-09-17T07:44:07Z
draft: false
authors: ['DCjanus']
tags: ['特斯拉', 'API', '物联网']
---

我常用来查看历史行程的第三方 Tesla App 在去年改为订阅制。为了继续掌握自己的行车数据，也趁机补上 Owner API 的细节，我动手写了一套自用的小工具，把一路摸索的经验整理成这篇笔记。内容主要参考 Tim Dorr 的非官方文档和个人实验数据，希望未来的自己能快速回忆关键步骤。

<!--more-->

## 前情提要

起初我只是凭直觉猜 Tesla 会提供开放接口，于是注册开发者账号、跟着文档尝试接入。验证阶段屡屡受阻才意识到这套体系比想象中复杂，针对不同人群的区分也相当明确。

### Fleet API 的适用范围

搜索时最显眼的是 [Fleet API](https://developer.tesla.com/docs/fleet-api/getting-started/what-is-fleet-api)。它面向企业与商业伙伴，申请通过后才能拿到生产环境的访问权。美国地区按照调用量计费，中国尚未公布收费计划；无论在哪个地区，个人车主都无法启用这一套接口。

### 社区项目指向的 Owner API

在多次碰壁之后，我转而翻看社区项目的源码。TeslaMate 等开源工具依旧调用的是 Owner API——也就是 Tesla 官方 App 使用的那组 HTTPS 接口。确认目标之后，接下来的任务就集中在鉴权、常用资源和数据采集。

> ⚠️ 提醒：Owner API 并不是面向第三方公开的产品，参数和权限都可能在没有通知的情况下调整。以下内容仅记录我的实验做法，请结合账号与车辆安全自行评估风险。

## 动手前的准备

在写脚本之前，我先处理几件基础工作：

- 确认账号可以顺利登录，并尽量开启两步验证。
- 备好便于发起 HTTP 请求的工具，如 `curl`、HTTPie 或 Postman。
- 把访问令牌和刷新令牌加密保存，通过环境变量注入运行环境。
- 调试时集中完成唤醒与测试，避免频繁唤醒车辆。

这些准备完成后，就可以逐步拆解 OAuth 登录流程。

## OAuth 登录流程

2021 年以后，Owner API 登录统一迁移到 Tesla SSO，并采用 PKCE。整体顺序如下：

1. 生成 `code_verifier`、`code_challenge` 和随机 `state`。
2. 在浏览器中打开授权页面，完成账号与 MFA 登录。
3. 从重定向的地址栏取出授权码，换取 SSO 访问令牌。
4. 使用 SSO 访问令牌兑换 Owner API 访问令牌。
5. 定期使用刷新令牌续期。

### 1. 生成 PKCE 参数

```bash
code_verifier=$(openssl rand -base64 86 | tr -d '=+/\n' | cut -c1-86)
code_challenge=$(printf "%s" "$code_verifier" | openssl dgst -binary -sha256 | openssl base64 | tr '+/' '-_' | tr -d '=\n')
state=$(openssl rand -hex 12)
```

### 2. 构造授权请求

复制下方链接到浏览器，替换为自己的 `code_challenge` 与 `state` 后发起登录：

```
https://auth.tesla.com/oauth2/v3/authorize?client_id=ownerapi&code_challenge=${code_challenge}&code_challenge_method=S256&redirect_uri=https%3A%2F%2Fauth.tesla.com%2Fvoid%2Fcallback&response_type=code&scope=openid%20email%20offline_access&state=${state}
```

授权回调使用 `https://auth.tesla.com/void/callback`。这个地址本身会返回 404，但依然有存在意义：

1. Tesla 尚未向第三方开放 Owner API 的鉴权接口，只能复用官方 App 的 `client_id`，而该 `client_id` 绑定在这个回调域名上。
2. 登录完成后虽然看到 404 页面，浏览器地址栏仍会携带 `code`，可以直接拿来换取访问令牌。

授权结束时，地址一般类似 `https://auth.tesla.com/void/callback?code=...&state=...`，把其中的 `code` 保存下来即可。如果账号归属中国区，需要把所有 `auth.tesla.com` 域名替换为 `auth.tesla.cn`，否则会遇到跨域或证书校验失败。

### 3. 用授权码换取 SSO 访问令牌

```bash
curl -X POST https://auth.tesla.com/oauth2/v3/token \
  -H 'Content-Type: application/json' \
  -d '{
    "grant_type": "authorization_code",
    "client_id": "ownerapi",
    "code": "<上一步的code>",
    "code_verifier": "'"$code_verifier"'",
    "redirect_uri": "https://auth.tesla.com/void/callback"
  }'
```

返回值包含 `access_token`（有效期约八小时）和 `refresh_token`（官方未公布期限，我的账号通常能用上数周）。

### 4. 交换 Owner API 访问令牌

```bash
curl -X POST https://owner-api.vn.teslamotors.com/oauth/token \
  -H 'Content-Type: application/json' \
  -d '{
    "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
    "client_id": "ownerapi",
    "client_secret": "<Owner API client_secret>",
    "assertion": "<SSO access_token>"
  }'
```

`client_secret` 可以在 Tim Dorr 的文档中找到，也可以自行抓包确认；若 Tesla 调整参数，只能再次想办法获取最新值。

### 5. 刷新令牌

```bash
curl -X POST https://owner-api.vn.teslamotors.com/oauth/token \
  -H 'Content-Type: application/json' \
  -d '{
    "grant_type": "refresh_token",
    "client_id": "ownerapi",
    "client_secret": "<Owner API client_secret>",
    "refresh_token": "<Owner API refresh_token>"
  }'
```

我通常会在脚本即将执行或察觉登录态不稳时主动刷新，避免任务中途因为过期而失败。不少社区脚本也会在 access_token 即将过期时自动替换
新令牌，并据此重新检测区域，以免后续请求走错线路。

### 区域识别与刷新策略

实验下来，无论是 SSO 返回的 JWT 还是 Owner API 提供的刷新令牌，都携带了可识别区域的信息：`iss` 包含 `.cn` 的令牌基本属于中国区，全球线路的刷新令牌通常以 `qts-`、`eu-` 等前缀开头，中国区则会以 `cn-` 起头。我的记录显示，SSO access_token 大约 8 小时过期，refresh_token 则能撑到 45 天左右。

我在定时任务里解析这些标记来决定后续 API 请求的域名，并把刷新窗口控制在令牌到期前的 30～45 分钟，避免真正过期后再去拉起流程。

### 使用第三方工具代办登录（可选）

如果不想亲自调用 OAuth 接口，也可以借助社区提供的登录辅助工具直接获取 `access_token` 与 `refresh_token`。这类方案会把账号凭据交给第三方，存在泄露风险，需要自行承担。常见的选项包括：

- [myteslamate.com 提供的网页助手](https://www.myteslamate.com/tesla-token/)
- [tesla_auth](https://github.com/adriankumpf/tesla_auth) 桌面应用
- [Auth App for Tesla](https://apps.apple.com/us/app/auth-app-for-tesla/id1552058613) 等移动 App

我目前仍习惯自己完成 OAuth 流程，只在调试别人的脚本时短暂使用这些工具。

## 常用接口与数据采集

我的目标是记录行程，因此只保留与车辆状态相关的接口。

### 基础端点与请求头

- REST API：北美与欧洲线路使用 `https://owner-api.vn.teslamotors.com`（老脚本里的 `owner-api.teslamotors.com` 目前仍然可用），中国线路对应
  `https://owner-api.vn.cloud.tesla.cn`。
- 流式遥测：北美与欧洲线路使用 `wss://streaming.vn.teslamotors.com/streaming/`，中国线路对应 `wss://streaming.vn.cloud.tesla.cn/streaming/`。
- 认证域名：需要与账号所在区域匹配，分别是 `https://auth.tesla.com` 与 `https://auth.tesla.cn`。

每次调用都要带上 `Authorization: Bearer <access_token>`，顺手放一个稳定的 `User-Agent`（例如自定义的 `MyTeslaScript/0.1.0`）能帮忙排查故障。

### REST API 轮询

常驻的几个接口如下：

- `GET /api/1/products`：列出账号下的车辆与能源设备。`/api/1/vehicles` 现在已经无法使用了。
- `GET /api/1/vehicles/{id}/vehicle_data`：获取车辆状态快照，我的定时任务完全依赖这一端点。
- `POST /api/1/vehicles/{id}/wake_up`：调试时手动唤醒，正式运行时尽量避免，减少能耗。

示例请求（北美、欧洲等地区）：

```bash
curl -H "Authorization: Bearer <Owner API access_token>" \
  https://owner-api.vn.teslamotors.com/api/1/products
```

> 🌐 线路差异：若账号在中国区，域名需要改为 `https://owner-api.vn.cloud.tesla.cn`。我自用的脚本会根据账号所在区域切换域名，同时把 OAuth 流程中的 `auth.tesla.com` 也替换成 `auth.tesla.cn`。

接口返回的每辆车会同时包含 `id`（REST 调用使用）与 `vehicle_id`（流式遥测使用）。社区经验普遍提醒不要混淆这两个字段。调用
`GET /api/1/vehicles/{id}/vehicle_data` 时，也可以通过 `endpoints=drive_state;charge_state` 等参数裁剪返回内容，减少带宽与解析压力。

### 定时抓取车辆状态

我会周期性调用 `GET /api/1/vehicles/{id}/vehicle_data`，把整车状态的快照写进数据库。返回值涵盖位置、电量、空调、轮胎压力、锁车状态等字段，足够用于行程回放。写入后，我会观察档位：如果车辆持续处于 P 挡超过五分钟，就认定行程已经结束，随后生成摘要推送到 Telegram，包括起止时间、地理位置、电量变化和平均速度。

REST 接口的数值大多遵循北美的英制单位：`drive_state.speed` 以 mph 表示车速，`odometer` 与相关里程字段使用 mile。为了在日常记录里保留公里与公里/小时等公制指标，我在入库前做一次换算，例如把 mph 乘以 1.609344 转换为 km/h，再根据需要保留两位小数。

### 订阅流式遥测

需要更高刷新率时，可以使用 WebSocket 流式接口：

1. 选用 `vehicle_id`（注意和 REST 接口的 `id` 区分）。
2. 连接 `wss://streaming.vn.teslamotors.com/streaming/`（中国区改为 `wss://streaming.vn.cloud.tesla.cn/streaming/`）。
3. 发送如下 JSON：

```json
{
  "msg_type": "data:subscribe_oauth",
  "token": "<Owner API access_token>",
  "value": "speed,odometer,soc,elevation,est_heading,est_lat,est_lng,power,shift_state,range,est_range,heading",
  "tag": "<vehicle_id>"
}
```

服务端会以 `msg_type=data:update` 推送一行逗号分隔的字符串，频率通常是一秒一次。字段顺序固定为时间戳、车速、里程、电量、海拔、方向、纬度、经度、功率、档位、续航、估算续航和航向角；常见的参考资料给出了常用单位，例如车速以 mph、里程以 mile、电量为百分比，功率以 kW 计算。我会在解析阶段顺便把 mph 与 mile 转换成 km/h 与 km，保证统计口径与其他驾驶记录保持一致。车辆离线或蜂窝网络断开时，连接不会自动关闭，只是长时间没有新消息。如果客户端没有超时逻辑，就会一直等待。TeslaMate 的做法是 30 秒内没有更新就主动断开 WebSocket，改为每 30 秒调用 JSON API；该接口会明确返回 `state`（例如 `offline`），便于判断当前状态。我在自用脚本里也沿用这一策略：超过 30 秒无数据就切回 REST 轮询，待车辆重新上线后再恢复流式订阅。

### 错误与重试

REST 与 WebSocket 遇到问题时返回的信息不尽相同。常见的 HTTP 状态码包括 401（令牌过期需刷新）、403（账号权限不足）、429（触发限流，按指数退避重试）以及 451（请求落在错误区域）。流式接口偶尔会返回 `data:error`，其中的 `vehicle_disconnected` 或 `Can't validate token` 等提示能帮助定位问题。

为了降低噪声，我把失败的请求做指数退避，最长等待 30 分钟；WebSocket 则增加心跳检测，避免假在线状态。不少脚本也会按照类似策略自动重连。

## 日常维护心得

为了让脚本运行得更稳，我在日常使用中保持以下习惯：

- 唤醒车辆后集中完成调试，避免反复唤醒。
- 参考 TeslaMate 的经验，把常规轮询间隔控制在 30 秒左右，遇到 HTTP 429 立即退避并延长间隔。
- 刷新令牌和访问令牌都存放在加密介质中，防止凭据泄露导致车辆被远程控制。

## 收尾

折腾 Owner API 完全是出于兴趣：既保留了行程记录，也顺手了解 Tesla 账号体系和车辆接口的细节。接口随时可能变化，只要注意账号安全与调用节奏，这套小工具就能稳定地记录每一次出行。
