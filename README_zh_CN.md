# MoonOCI

MoonOCI 是一个原创的 MoonBit 库与命令行工具，用于在不依赖容器守护进程和远程镜像仓库的情况下，构建、检查和验证确定性的 OCI Image Layout。

项目由可移植核心、内存适配器、Native 文件系统适配器和轻量 CLI 组成。相同的声明式输入会产生字节完全一致的 tar Layer、OCI JSON、Descriptor 和内容寻址 Blob。

**0.2.0** 新增多平台合并与选择、缺失内容增量归档、可信摘要锁定与离线重建、可达性统计／布局整理、Blob 索引，以及覆盖全部平台的发布策略。Windows 可运行独立观察与离线交付消费者，Linux 消费链路由 CI 验证。使用与边界见 [离线交付](docs/offline-delivery.md) 和 [无需本地虚拟机的验证方式](docs/runtime-validation.md)。

## 已实现功能

Windows 上已跑通两条独立消费链路。MoonOCI 可经 HTTP/TLS 读取固定摘要的布局，
分页发现附件，验证附件实际 subject 和原始 in-toto Statement 的内部摘要，再按多平台
策略放行离线布局。ORAS 已从 Docker Hub 下载固定摘要的 Alpine，MoonOCI 与 CPython
逐条对照 517 项文件清单。复现方法和公网连接限制见
[Registry 消费](docs/registry-transport.md)与[证明绑定](docs/statement-verification.md)。

[混合内容生命周期](docs/content-lifecycle.md) 新增物理内容目录、镜像与附件保留闭包、扩展字段保留及审阅 pin；物理源内容变更后拒绝旧计划，Native 导出还会执行支持范围内的镜像／附件语义验证。Windows 上已用 CPython 与 ORAS 独立验证，不删除源布局。已验证状态的内部容器现通过显式 `priv` 字段隔离，见 [接口封装修复](docs/api-encapsulation.md)。

0.2.0 另加入 [可恢复离线交付](docs/resumable-delivery.md)：分块计划、磁盘检查点复核、按字节／块数限制缺失任务批次、整包摘要验证及中断临时文件恢复。Windows 独立消费者已实际完成“增量包分块—跨进程续传—重建镜像—独立校验”链路；长驻宿主可复用已验证会话。此链路不需要本地 Linux 或虚拟机，容器运行验证仍由单独的 Linux CI 承担。

- 确定性 USTAR/PAX 写入器，以及支持 USTAR、PAX、GNU longname/longlink 的安全读取器；
- SHA-256 Digest 与内存 OCI Image Layout；
- 未压缩 Layer 和确定性 gzip Layer；
- 正确区分压缩 Layer Digest 与未压缩 DiffID；
- 多层顺序构建、Whiteout 与 Opaque Directory 语义；
- `schemaVersion: 1` 严格 Build Specification；
- Descriptor 引用图、大小、摘要、tar、gzip 与 DiffID 验证；
- Root Filesystem 重建；
- Native `build`、`inspect`、`list`、`verify`、`archive`、`version` 命令；
- 属性测试、损坏输入测试、Native 文件系统测试和可复现性测试。

## 功能边界

v0.1 每次构建一个平台镜像，目标格式为 OCI Image Spec 1.1.1。项目不解析 Dockerfile，不运行容器，不访问 Registry，不执行签名，也不支持 zstd。可移植归档 API 支持符号链接；由于当前 Native 文件系统依赖没有跨平台 `readlink` 接口，Native Layer Source 在 v0.1 中会明确拒绝主机符号链接。

## 安装

在 MoonBit 项目中添加已发布的库：

```text
moon add oyjh0381/moonoci@0.4.0
```

可复用包包括 `oyjh0381/moonoci/archive`、`builder`、`codec`、`digest`、`layout`、`model`、`pathing` 和 `spec`。Native CLI 需要从本源码仓库构建并运行。

## 构建与测试

开发分支使用 MoonBit 编译器与标准库 `0.10.20+65efd5b93`，配套
`moon` 为 `0.1.20261104`。

```text
moon update
moon check --target all
moon test --target wasm-gc
```

Windows Native 构建需要 Visual Studio 2022 Build Tools、C++ 工作负载和 Windows SDK，并应在开发者命令行中执行：

```text
moon test --target native
moon build --target native
```

运行示例：

```text
moon run examples/single-layer --target wasm-gc
moon run examples/multi-layer --target wasm-gc
moon run examples/reproducible --target wasm-gc
```

## CLI

在源码仓库中运行 Native CLI：

```text
moon run cmd/moonoci --target native -- build moonoci.json
moon run cmd/moonoci --target native -- inspect dist/image
moon run cmd/moonoci --target native -- list dist/image
moon run cmd/moonoci --target native -- verify dist/image
moon run cmd/moonoci --target native -- archive dist/image dist/image.tar
moon run cmd/moonoci --target native -- version
```

Build Specification 的完整字段、默认值和限制见 [`docs/build-spec.md`](docs/build-spec.md)。安全边界见 [`docs/security.md`](docs/security.md)，兼容与验收状态见 [`docs/conformance.md`](docs/conformance.md)。

## 开源许可证

MoonOCI 采用 Apache License 2.0。第三方依赖及许可证见 `THIRD_PARTY_NOTICES.md`。
