# 可用组合（2026-11-18 实测通过）

> 结论：**无 root、容器内跑国服 + Hachimi，登录与资源下载均正常，进程稳定 7.5 分钟以上**。
> 关键是用 metadata hook + 库名伪装，绕开 ACE 的两道检测。

## 一、最终生效的组合

| 层 | 做法 | 作用 |
|---|---|---|
| 1 | 容器 BlackBox（自编译，固定签名） | 原版 APK 零改动运行 |
| 2 | `nativelib` 目录重定向（`libmain.so`→原版、`libmain_orig.so`→原版） | 让游戏从我们控制的目录加载 |
| 3 | 晚加载 Hachimi（8s 后 `System.load`） | 不替换 libmain，避免 Unity 初始化错位 |
| 4 | **自解析符号**（`/proc/self/mem` + ELF dynsym，取 `r-xp` 段基址） | 不依赖 dlopen，绕过加密与命名空间 |
| 5 | **metadata hook**（改 `MethodInfo->methodPointer`） | 不改代码字节 → 绕过 `inline_hook_opcode_dismatch` |
| 6 | **库名伪装**（真实文件 `libcri_core.so`，`libhachimi.so` 只是符号链接） | 绕过 `/proc/pid/maps` 扫描 |
| 7 | `disable_gui: true` | 不装 eglSwapBuffers/nativeInjectEvent 这两个 inline hook |

## 二、配置（`/sdcard/Android/media/com.bilibili.umamusu/hachimi/config.json`）

```json
{
  "language": "zh-cn",
  "late_load": true,
  "poll_il2cpp": true,
  "disable_dlopen_hook": true,
  "disable_gui": true,
  "debug_mode": true,
  "ui_animation_scale": 3.0
}
```

加速靠 `ui_animation_scale`（GUI 滑块上限 10，配置文件可超），不需要打开菜单。

## 三、跳过的 5 个 hook

`LoadAsset_Internal` / `LoadAssetAsync_Internal` / `LoadFromFile_Internal` / `Unload`（AssetBundle）
`set_targetFrameRate`（帧率）

原因：它们的地址没记录进 `methodPointer → MethodInfo` 映射，无法做指针替换；为保证"零代码改动"直接跳过。

## 四、未生效的尝试（留档）

- hook `libc kill()` → 装上去就崩（1 秒内 SIGSEGV），**别再用**
- hook `android_os_Process_sendSignal` → 该符号未导出，dlsym 取不到（`sendSignal symbol not found`）
- 移除 `libtprt.so`/`libtersafe2.so` → `libil2cpp.so` 的 DT_NEEDED 依赖它们，游戏直接加载不了

## 五、构建产物

- 公开仓库 `xf8410/Dsh-so-Agora`：`.github/workflows/hachimi-build.yml` + `tools/meta_patch.sh`
  （私有仓库 Actions 额度耗尽后改用公开仓库构建，免费）
- 产物：release `builds` 里的 `libhachimi-sig-*.so`
- 手机上：`/sdcard/Download/libhachimi.so` → 容器启动时写入 `files/nativelib/libhachimi.so`（符号链接）→ 真实文件 `libcri_core.so`