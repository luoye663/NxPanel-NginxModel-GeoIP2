# GeoIP2 构建目标

本模块使用上游 GeoIP2 3.4，动态符号为 `ngx_http_geoip2_module`。发布步骤见[仓库说明](../../README.md)。

在 [`publish-targets.json`](../../publish-targets.json) 为每套运行时写一条配方：

| 目标 | `builder` | 镜像和要固定的输入 |
| --- | --- | --- |
| 宿主机 Nginx/OpenResty | `host` | 对应发行版基础镜像的摘要、上游软件包 `package_version` 和源码 `runtime_sha256` |
| Alpine Nginx/OpenResty | `alpine` | 含目标 Nginx/OpenResty 二进制的现有镜像摘要、与该二进制对应的 `runtime_sha256` |

当前配方均为 `amd64`，各目标进入同一个 Release。宿主机目标使用运行时官方软件包，包版本和指纹以 `publish-targets.json` 为准。

| 配方的构建环境 | 清单系统键 | 运行时 |
| --- | --- | --- |
| Debian 13 | `debian:13` | Nginx |
| Ubuntu 22.04 | `ubuntu:22.04` | OpenResty |
| Ubuntu 24.04 | `ubuntu:24.04` | Nginx、OpenResty |
| Rocky Linux 9.8 | `rocky:9` | Nginx、OpenResty |
| Alpine 3.21 | `alpine:3.21` | Nginx |

Debian 13.x、Ubuntu 24.04.x 和 Rocky 9.x 不按点版本拆分产物。同系列系统仍须满足运行库依赖，且架构、运行时类型、版本、二进制 SHA-256 均须匹配；更新运行时软件包后，若指纹变化，需为新二进制发布对应产物。Debian 13 不提供 OpenResty 配方，因为上游没有原生 `trixie` 软件源。

新增目标时为实际环境填写唯一的 `name`、`os`、`arch` 和 `runtime`。配方的 `binary_sha256` 从实际运行时计算（Ubuntu 22.04 必填），最终 `target.json` 由构建脚本生成。新发行版的包来源、依赖或二进制路径不同时，先适配构建脚本。要支持 Alpine OpenResty，就添加匹配实际 OpenResty 镜像的 `alpine` 配方，不复用 Nginx 的 `.so`。

安装脚本以 root 运行，先试载并检查配置，再平滑重载；缺少 `libmaxminddb` 时只使用已有系统软件源。验收会实测安装、查询和卸载。新增配方依赖 NxPanel 构建脚本改动时，先合入主仓库，再将本仓库的 `.github/nxpanel-tools.sha` 固定到包含该改动的完整提交 SHA。
