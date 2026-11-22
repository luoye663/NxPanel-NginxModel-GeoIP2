# NxPanel GeoIP2 模块仓库

本仓库的 Actions **编译 → 打包 → 验证 → 签名 → 发布**。各目标的 `.so` 发布到同一个 GitHub Release。宿主机和 Alpine 编译都在本仓库；打包、验收和签名使用固定版本的 NxPanel 工具。新增系统或运行时版本不需改主仓库。

| 路径 | 用途 | 提交到 Git？ |
| --- | --- | --- |
| `modules/geoip2/` | 宿主机和 Alpine 构建、安装与卸载脚本源码 | 是 |
| `publish-targets.json` | 构建目标、镜像摘要和上游源码摘要 | 是 |
| `.work/builds/` | `.so`、实测的 `target.json`、拼装后的脚本 | 否 |
| `.work/bundle/` | 唯一候选包；签发时只新增清单和签名 | 否 |

## 发布

1. 确认 `publish-targets.json` 覆盖预期目标，见 [GeoIP2 构建目标](modules/geoip2/README.md)。
2. 在本仓库 **Actions → Publish GeoIP2 module → Run workflow** 选择默认分支，填尚未使用的正式版本 tag，例如 `v3.4.0`。
3. 各目标验完后审核签名任务。Actions 创建 tag 和草稿 Release，上传 `.so`、安装／卸载脚本、`module-release.json` 和 `module-release.sig.json`，再转为正式版。`candidate.json` 只保留在 CI 产物中。

不要覆盖资产或重用 tag。若在上传时失败，可能留下 tag 或草稿；检查后使用新 tag。首次发布还需在 NxPanel 主仓库登记此仓库和模块公钥。

<details>
<summary>首次配置 Actions</summary>

在可信的 NxPanel 源码根目录生成此模块独用的密钥：

```sh
umask 077
go run ./cmd/nxpanel-update-package -keygen "$HOME/nxpanel-geoip2-release-key" -key-id geoip2-1
```

| 配置位置 | 名称 | 填什么 |
| --- | --- | --- |
| Actions 仓库变量 | `NXPANEL_MODULE_RELEASE_TRUST_KEYS` | 模块 `trust.pub` 的完整一行，用于核对签名密钥；同一行填到 NxPanel 索引的 `keys`。 |
| `module-release-signing` 环境 Secret | `NXPANEL_MODULE_RELEASE_SIGNING_KEYS` | 模块 `signing.key` 的完整一行，用于签发 Release。 |

粘贴文件里的 `key-id:BASE64`，不填文件名或路径。`module-release-signing` 只允许默认分支，且要求审批。不要提交私钥，也不需要 NxPanel 索引私钥。

工具版本由模板维护者固定在 `.github/nxpanel-tools.sha`，不用配 Actions 变量。开发模板缺少这个文件时不会发布；先取得含该文件的完整模板，再运行发布工作流。

</details>

## 环境变量配置

1. 在 NxPanel-NginxModel-GeoIP2 仓库打开 Settings → Secrets and variables → Actions → Variables，创建或修正 Repository variable NXPANEL_MODULE_RELEASE_TRUST_KEYS。
2. 值填现有 GeoIP2 密钥对中 trust.pub 的完整一行，格式为 key-id:BASE64，包含冒号和尾部的 =（如有）。不要填文件路径、只填 Base64，或把公钥建成 Secret。主仓库的 NXPANEL_MODULE_TRUST_KEYS 也不能替代这个变量。
3. 私钥保持在模块仓库 Settings → Environments → module-release-signing 的 Secret NXPANEL_MODULE_RELEASE_SIGNING_KEYS 中，必须来自同一对密钥的 signing.key。已有配对密钥就不需要重新生成。
4. 保存后发起 Publish GeoIP2 module。

## 本地编译与验证

依赖 Docker、Bash、`jq` 和 NxPanel `go.mod` 所需的 Go 版本。在本仓库根目录运行：

```sh
bash prepare-release.sh /path/to/nxpanel owner/repo v3.4.0
bash prepare-release.sh /path/to/nxpanel owner/repo v3.4.0 verify
```

第一条为本机架构编译、打包，第二条做真实安装／卸载验证。都不需要私钥，不上传。重新构建时使用新的 `MODULE_WORK_DIR`，避免误混旧文件。CI 使用相同入口：`bash prepare-release.sh - owner/repo v3.4.0 build` 不需要 NxPanel checkout 或 Go，按架构输出编译产物；`bundle` 汇总所有架构，`verify` 按架构验证同一个候选包。

只为本机已安装的官方运行时生成联调候选包时，运行：

```sh
MODULE_NGINX_BIN=/usr/local/openresty/nginx/sbin/nginx \
  bash prepare-release.sh /path/to/nxpanel owner/repo v3.4.0 local-host
```

没有匹配的发布配方时，通过 `MODULE_RUNTIME_SHA256` 提供已核验的运行时源码归档摘要。需要向构建容器传递代理时，设置 `MODULE_BUILD_USE_PROXY=1`。默认产物 `.work/local-host/bundle/` 仅供联调，不用于正式发布；按 NxPanel 的 `docs/function/nginx-modules.md`「本地联调」一节，将它或匹配的正式候选包转成 `module_dev` 测试源。
