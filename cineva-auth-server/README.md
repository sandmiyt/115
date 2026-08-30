# Cineva 115 授权服务

这个服务把 115 开放平台的网页授权安全地接回 iPhone App。`client_secret` 只保留在服务端；App 回调只携带五分钟有效、只能兑换一次的随机票据，访问令牌不会出现在回调 URL 中。

## 配置

1. 在 115 开放平台创建应用，将授权回调地址设置为：

   `https://你的授权域名/115cloud/callback`

2. 复制 `.env.example` 并填写：

   - `CINEVA_115_CLIENT_ID`：115 应用 ID
   - `CINEVA_115_CLIENT_SECRET`：115 应用密钥，只能放在服务端
   - `CINEVA_115_PUBLIC_BASE_URL`：服务的公网 HTTPS 根地址
   - `CINEVA_115_APP_CALLBACK_URL`：保持 `cineva115://oauth/115`
   - `CINEVA_AUTH_SIGNING_SECRET`：至少 24 位的随机密钥
   - `CINEVA_AUTH_DB`：SQLite 持久化路径

3. 部署后确认 `https://你的授权域名/health` 返回 `status: ok`。

4. 将 iOS 工程 `Gallery115/Info.plist` 的 `Cineva115AuthorizationURL` 设置为：

   `https://你的授权域名/115cloud/requests`

## Docker

```sh
docker build -t cineva-115-auth .
docker run -d --restart unless-stopped --env-file .env -p 8080:8080 -v cineva-auth-data:/data cineva-115-auth
```

公网入口必须通过反向代理提供有效 HTTPS 证书。不要把 `.env`、`client_secret`、签名密钥或数据库提交到 Git。
