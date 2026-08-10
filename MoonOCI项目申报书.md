# 项目申报书

## MoonOCI 项目申报书

**基本信息**

- 项目名称：MoonOCI：确定性 OCI Image Layout 构建与验证工具

- 参赛者：**【待填写】**

- 联系方式：**【待填写】**

- GitHub 仓库链接：https://github.com/oyjh0381/MoonBit.git

- 项目方向：MoonBit 原生 OCI 镜像开发工具 / 可复现构建与供应链基础设施

- 是否为移植项目：否，为原创 MoonBit 项目

- 开源许可证：Apache License 2.0

**项目简介**

MoonOCI 是一个使用 MoonBit 实现的确定性 OCI Image Layout 构建、检查与验证项目。它不依赖 Docker 守护进程、容器运行时或远程 Registry，可从声明式 Layer Source 构建符合 OCI Image Spec 1.1.1 的内容寻址镜像布局，并对 Image Index、Image Manifest、Image Configuration、Layer Descriptor、Blob、tar、gzip 和 DiffID 关系进行完整验证。

项目面向 MoonBit 库作者、构建工具开发者、CI/CD 平台、供应链工具和需要生成 OCI 工件的应用。相同声明式输入会产生字节一致的 Layer、OCI JSON、Descriptor 与 Digest，便于缓存、审计、复现实验和跨机器验证。

项目采用两级深模块架构：可移植核心可在 Wasm、Wasm-GC、JavaScript 和 Native 目标上检查或复用；Native 适配器负责真实文件系统与 CLI。当前仓库包含 13 个 MoonBit package、41 个 `.mbt` 文件和约 4258 行 MoonBit 源码。

**核心功能范围**

- 提供经过校验的 SHA-256 Digest、Descriptor、Image Index、Image Manifest、Image Configuration、Platform、Runtime Config 和结构化 Validation Finding 模型；

- 提供确定性 USTAR/PAX tar 写入器，按 UTF-8 路径字节序排序，规范化 uid、gid、mtime 和默认权限，并支持长路径、长链接、普通文件、目录、符号链接、Whiteout 与 Opaque Directory 标记；

- 提供安全归档读取器，支持 USTAR、POSIX PAX、GNU longname/longlink，校验 header checksum、octal 溢出、payload、padding、结束块、UTF-8 与重复路径，并拒绝 sparse、设备、socket、FIFO 等不安全类型；

- 支持未压缩 Layer 与确定性 gzip Layer，正确区分压缩 Layer Digest 和未压缩 DiffID；

- 支持有序多层镜像构建，正确应用文件替换、Whiteout 删除和 Opaque Directory 继承隐藏语义，并可重建最终 Root Filesystem 视图；

- 提供 `schemaVersion: 1` 严格 Build Specification，覆盖平台、Layer Source、压缩、删除、opaque、排除、ignore file、metadata、运行配置、annotations 与输出目录；

- Build Specification 限制为 16 MiB 与 128 层嵌套，拒绝未知字段、重复 JSON key、非法路径、非法压缩方式和不兼容配置；

- 提供内存内容寻址 OCI Image Layout，构建时生成 config、manifest、index 和 Blob，并对相同内容去重；

- 提供 Descriptor 图验证，检查每个 Blob 的存在性、大小、SHA-256、媒体类型、tar 内容、gzip CRC/ISIZE、DiffID 和 Layer 数量关系；

- gzip 构建输入限制为 256 MiB；验证时解压输出限制为 512 MiB，并拒绝高于 200:1 的膨胀率；tar 默认限制 1,000,000 个条目，路径与链接目标限制为 4096 UTF-8 字节；

- 提供 Native 文件系统适配器，通过 staging directory 写入并原子重命名，拒绝覆盖既有输出；

- 提供 `moonoci build`、`inspect`、`list`、`verify`、`archive`、`version` 和 `help` 命令，以及稳定的错误代码与退出状态分类；

- 提供 single-layer、multi-layer、reproducible-build 三个可执行 MoonBit 示例，以及一个 Native Build Specification 示例；

- 提供 53 个命名测试；其中两项 QuickCheck 属性测试各运行 100 个生成场景，并包含 60 个安全路径矩阵场景、损坏归档、摘要篡改、gzip 高膨胀率、Native 文件系统和可复现构建测试；

- 配置 Ubuntu 与 Windows GitHub Actions，执行 formatter、全目标类型检查、WASM-GC 测试、Native 测试、示例、CLI 构建，并在 Linux 使用 Skopeo 独立读取生成的 OCI Image Layout；

- 提供英文 README、中文 README、可执行 README、Build Specification、架构、安全模型、兼容性、发布清单、ADR、术语表、变更日志、Apache-2.0 LICENSE 与第三方依赖声明。

**功能边界与后续方向**

- v0.1 每次构建一个平台镜像，不负责多平台索引聚合；

- 不解析 Dockerfile，不执行构建指令，不启动容器，不连接 Registry，不进行签名、证明、加密和镜像分发；

- v0.1 支持未压缩与 gzip Layer，不支持 zstd；

- 可移植归档 API 支持符号链接；由于当前 Native 文件系统依赖没有跨平台 `readlink`，Native Layer Source 会明确拒绝主机符号链接；

- 不支持 sparse file、设备节点、socket、FIFO、ACL 与扩展属性；

- v0.1 采用内存构建，适合文档规定的资源上限；后续可在保持相同摘要和安全边界的前提下增加流式 Blob adapter、Registry transport、多平台组装和签名/证明扩展。

**原创、参考与开源合规说明**

- 本项目不是对某个现有程序库的逐行移植，核心架构、MoonBit 类型、确定性编码、Build Specification、内存布局、Native 适配器和测试均为原创实现；

- 格式和语义依据 OCI Image Format Specification 1.1.1，包括 Image Layout、Descriptor、Manifest、Configuration、Layer、Whiteout 与 DiffID 定义；

- Skopeo 仅作为 CI 中的独立兼容性验证工具，不复制其实现代码；

- 直接依赖 `moonbitlang/x`、`mizchi/zlib`、`moonbitlang/async` 和 `moonbitlang/quickcheck`，四者均采用 Apache License 2.0，具体版本、链接与用途已写入 `THIRD_PARTY_NOTICES.md`；

- 项目采用 Apache License 2.0，未包含私有、闭源、商业或来源不明代码。

**当前验收证据**

- `moon fmt --check`：通过；

- `moon check --target all --deny-warn`：通过；

- `moon test --target wasm-gc --deny-warn`：51/51 通过，QuickCheck 额外完成 200 个生成场景；

- `moon test --target native --deny-warn`：53/53 通过；

- `moon build --target native --deny-warn`：通过，已生成并运行 `moonoci.exe`；

- single-layer、multi-layer、reproducible 三个示例：均已实际运行通过；

- `moonoci version` 与 `moonoci help`：已实际运行通过；

- mooncakes.io：发布元数据和发布清单已准备，尚未登录或执行正式发布。

## Q33：参赛者及联系方式最终确认

> **【待填写】**

提交前请在本节以及“基本信息”中的参赛者、联系方式处填写一致的最终信息。
