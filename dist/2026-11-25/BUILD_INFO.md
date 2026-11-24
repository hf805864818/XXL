# PetDFY 本地全功能编译产物 · 2026-11-25

构建命令：

```bash
make clean all ARCHS="arm64 arm64e" TARGET=iphone:clang:16.5:16.0
```

工具链：CodexApp `TheosRuntime`（clang 16 + iPhoneOS16.5.sdk）。

| 架构 | 文件 | 大小 | SHA256 |
|---|---|---:|---|
| arm64 | `PetDFY.dylib` | 2454752 | `a01f619d2f80d2ffc0e1ed24d475042ce106b80a87f33959b42e0cde7f870757` |
| arm64 | `PDFYEnhance.dylib` | 73840 | `ba2d4521125d37cd4e58f3594319e3411750b24c49ffb01d3bc82a0f942ac775` |
| arm64 | `PDFYSecurity.dylib` | 66864 | `baf58fdc20f11adf643b8b99013137c29ae6bf2aff1e1ea1bdbbde502bdba7f8` |
| arm64e | `PetDFY.dylib` | 2511696 | `17089f3726c5bd41479b525201fa821f49a0c1a535b984527bf4c6c0ecc8c89c` |
| arm64e | `PDFYEnhance.dylib` | 73520 | `c038c2023658c5797f3b99c4369d7c3cd799a57f592026a41950952f991f31fa` |
| arm64e | `PDFYSecurity.dylib` | 66768 | `e0d4243ece464fb5efd42a2118c7e298ddb447f52ec8a9dcd7d5963c52a768de` |

说明：

- `PetDFY.dylib` 是主 tweak，`PDFYEnhance.dylib` / `PDFYSecurity.dylib` 是辅助 dylib。
- arm64e 切片 `cpusubtype = 0x80000002`，是真正的 arm64e，不是改名的 arm64。
- 本目录只放编译产物；素材仍在 `assets_src/`，安装时需 `make assets` 或使用素材 deb。
- 这些产物是“编译通过”的快照，尚未经过 e2 真机出画面验证。
