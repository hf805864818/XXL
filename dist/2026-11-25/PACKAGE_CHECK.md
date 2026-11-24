# 本地打包验证 · 2026-11-25

```bash
make assets
mkdir -p layout/DEBIAN
cp control layout/DEBIAN/control
cp .theos/obj/debug/arm64e/{PetDFY,PDFYEnhance,PDFYSecurity}.dylib \
   layout/Library/MobileSubstrate/DynamicLibraries/
dpkg-deb -b layout packages/PetDFY_0.1.8-e1-local_iphoneos-arm64e.deb
```

结果：

| 项 | 值 |
|---|---|
| 文件 | `PetDFY_0.1.8-e1-local_iphoneos-arm64e.deb` |
| 大小 | 35,481,256 B（约 34 MB） |
| Package | `com.ojbkclub.petdfy` |
| Version | `0.1.8-e1` |
| Architecture | `iphoneos-arm64e` |
| SHA256 | `87b8cffb68afbbaf86dd1ae3888f6cf3e943134e231ea780f3d69dc892d4f56e` |

包内已确认：

```text
./Library/Application Support/PetDFY.bundle/live/model.json   111046 B
./Library/MobileSubstrate/DynamicLibraries/PetDFY.dylib       2511696 B
./Library/MobileSubstrate/DynamicLibraries/PDFYEnhance.dylib    73520 B
./Library/MobileSubstrate/DynamicLibraries/PDFYSecurity.dylib   66768 B
```

说明：deb 含 33 MB 素材，所以体积大；这是本地安装验证包，未上传到 GitHub Release。
