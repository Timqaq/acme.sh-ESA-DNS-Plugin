# dns_ali_esa — acme.sh DNS API plugin for Alibaba Cloud ESA

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

[acme.sh](https://github.com/acmesh-official/acme.sh) 的阿里云 ESA（边缘安全加速）DNS 验证插件，支持通过 ESA DNS API 自动完成 ACME DNS-01 challenge，申请/续签 Let's Encrypt 等证书。

| 操作 | 权限 |
|------|------|
| 查询站点 | `esa:ListSites` |
| 查询 DNS 记录 | `esa:ListRecords` |
| 创建 DNS 记录 | `esa:CreateRecord` |
| 删除 DNS 记录 | `esa:DeleteRecord` |

## 安装

```sh
cp dns_ali_esa.sh ~/.acme.sh/dnsapi/
chmod +x ~/.acme.sh/dnsapi/dns_ali_esa.sh
```

## 配置

| 环境变量 | 必填 | 说明 |
|----------|------|------|
| `Ali_ESA_Key` | ✅ | 阿里云 AccessKey ID |
| `Ali_ESA_Secret` | ✅ | 阿里云 AccessKey Secret |
| `Ali_ESA_Region` | ❌ | ESA 地域，默认 `cn-hangzhou`，海外用 `ap-southeast-1` |
| `Ali_ESA_SiteId` | ❌ | 站点 ID，留空则自动通过域名查找 |

首次配置后，acme.sh 会自动将配置保存到 `~/.acme.sh/account.conf`，后续续签无需重新 export。

## 使用

```sh
# 设置凭证
export Ali_ESA_Key="your_access_key_id"
export Ali_ESA_Secret="your_access_key_secret"

# 申请单域名证书
acme.sh --issue --dns dns_ali_esa -d example.com

# 申请通配符证书（需同时验证裸域名和通配符）
acme.sh --issue --dns dns_ali_esa -d example.com -d "*.example.com"

# 申请多域名证书
acme.sh --issue --dns dns_ali_esa -d example.com -d sub.example.com
```

## 调试

若遇到问题，加 `--debug 2` 参数可查看完整签名串和 API 请求/响应：

```sh
acme.sh --issue --dns dns_ali_esa -d example.com --debug 2
```

## 常见错误

| 错误码 | 原因 | 解决方法 |
|--------|------|----------|
| `MissingSignature` | 签名未生成，通常是 `openssl` 不可用 | 确认 `openssl` 已安装 |
| `InvalidAccessKeyId` | AK 错误或已被禁用 | 检查 `Ali_ESA_Key` |
| `SignatureDoesNotMatch` | SK 错误 | 检查 `Ali_ESA_Secret` |
| `Cannot find ESA site` | 域名未接入 ESA，或地域不对 | 确认域名已在对应 Region 的 ESA 中，并检查 `Ali_ESA_Region` |

## 工作原理

1. 通过 `ListSites` 接口逐级查找域名对应的 ESA 站点，获取 `SiteId`
2. 调用 `CreateRecord` 在该站点下创建 `_acme-challenge` TXT 记录
3. ACME 验证通过后，调用 `DeleteRecord` 清理记录
4. 所有写操作（Create/Delete）使用 HTTP POST，读操作使用 GET，均通过 HMAC-SHA1 签名鉴权

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
