# GeoIP2 构建目标

本模块使用上游 GeoIP2 3.4，动态符号为 `ngx_http_geoip2_module`。发布步骤见[仓库说明](../../README.md)。

在 [`publish-targets.json`](../../publish-targets.json) 为每套运行时写一条配方：

| 目标 | `builder` | 镜像和要固定的输入 |
| --- | --- | --- |
| 宿主机 Nginx/OpenResty | `host` | 对应发行版基础镜像的摘要、上游软件包 `package_version` 和源码 `runtime_sha256` |
| Alpine Nginx/OpenResty | `alpine` | 含目标 Nginx/OpenResty 二进制的现有镜像摘要、与该二进制对应的 `runtime_sha256` |

两类都填写唯一的 `name`、`os`、`arch` 和 `runtime`。已有示例是 Ubuntu 22.04 的 OpenResty 和 Alpine 3.21 的 Nginx，都是 `amd64`。`binary_sha256` 是可选的额外校验值（Ubuntu 22.04 必填）；从目标运行时实际计算，不猜测。记录最终 `target.json` 的是构建脚本，而不是手填配置。

新增支持时复制一条最接近的配方，换成该目标的实际环境。已有宿主机构建助手支持 Debian 12、Ubuntu 22.04/24.04、Rocky 9；新发行版的包来源、依赖或二进制路径不同时，先适配相应脚本，再把它加入发布。要支持 Alpine OpenResty，就再加一条和实际 OpenResty 镜像匹配的 `alpine` 配方，不复用 Nginx 的 `.so`。

安装脚本以 root 运行，先试载并检查配置，再平滑重载；缺少 `libmaxminddb` 时只使用已有系统软件源。验收会实测查询和卸载。某个目标通过不代表同发行版的其他 Nginx 也兼容，Agent 仍按实际二进制指纹选择产物。
