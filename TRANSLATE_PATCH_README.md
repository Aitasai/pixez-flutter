# PixEz 小说翻译补丁

为 PixEz Flutter 小说阅读页加入 AI / 传统机翻翻译功能，并让导出能带上译文。

整个补丁**不新增任何依赖**——`shared_preferences`（配置持久化）与 `dio`（HTTP 请求）都已是上游 `pubspec.yaml` 中的依赖；mobx / flutter_mobx 也是上游已用。因此上游升级时几乎不会因 `pubspec.yaml` 变化产生冲突。

---

## 一、功能特性

- **方案 A：OpenAI 兼容** —— 一套接口覆盖 OpenAI / DeepSeek / 智谱 GLM / Moonshot Kimi / OpenRouter / 本地 Ollama 等所有 `/v1/chat/completions` 兼容服务。
- **方案 B：传统机翻** —— Google Translate v2、微软 Azure Translator，仅需 API Key。
- 翻译对象：**小说标题 + 简介(caption) + 正文(body)** 三者分别翻译。
- 翻译后可一键**原文 ↔ 译文切换**显示。
- **导出功能适配译文**：当处于译文显示态时，导出的 `.txt` 内容 = 译文标题 + 译文简介 + 译文正文（标记已转成自然语言分隔符，可读性好）；切回原文时导出维持上游原样。
- 正文标记（`[pixivimage:1-2]`、`[newpage]`、`[uploadedimage:..]`、`[[jumpuri:..]]`、`[[rb:..]]`、`[chapter:..]`）在翻译前后用低频占位符保护、译后还原，因此**译文里嵌入的插画/分页/章节标题仍然能正常渲染**，复用 `NovelSpansGenerator` 的解析逻辑。

## 二、改动文件清单

| 文件 | 类型 | 说明 |
|------|------|------|
| `lib/translate/translate_service.dart` | **新增** | 翻译服务 + 配置类 + 持久化；A/B 两套实现；占位/分块/还原 |
| `lib/translate/readable_text.dart` | **新增** | 导出文本用：标记 → 自然语言可读文本 |
| `lib/translate/translate_setting_page.dart` | **新增** | 设置页：选 provider / 填 URL/Key/模型/目标语言/系统提示 |
| `lib/page/novel/viewer/novel_store.dart` | **修改** | 新增 mobx 字段 `translating / translatedTitle/translatedCaption/translatedBody/translatedSpans/translateError` 与 `@action doTranslate()`；其余逻辑原样保留 |
| `lib/page/novel/viewer/novel_viewer.dart` | **修改** | `_showMessage` 新增三项目（翻译本文 / 显示原文·译文 / 翻译设置）；`_buildBody`、`_buildHeader` 按 `showTranslation` 切换；`_export` 在译文态导出译文 |
| `.github/workflows/build_novel_translate_apk.yml` | **新增** | GitHub Actions：一键编译 release APK |

所有 Dart 改动都以 `[PIXEZ-TRANSLATE-PATCH] ADD` 形式标记，方便未来 rebase 时一眼识别。

## 三、使用方法（用户侧）

1. 打开小说 → 右上角 `⋮` 菜单 → **翻译设置**，选择翻译服务并填配置：
   - **OpenAI 兼容**：填 API URL（默认 OpenAI 官方，可改成其他服务商）、
     API Key、模型名（如 `gpt-3.5-turbo` / `deepseek-chat` / `glm-4`）、
     可选自定义系统提示词、目标语言（默认 `zh-CN`）。
   - **Google**：填 Google Cloud Translation API Key，目标语言如 `zh-CN`。
   - **微软 Azure**：API Key 填入 Key 框，URL 默认官方；**模型名字段请填资源所在 region**（例如 `eastasia` / `japaneast`——Azure 文档称 `Ocp-Apim-Subscription-Region`）。
2. 回到小说菜单 → 点 **翻译本文**，完成后自动切换为译文显示。
3. 之后可通过 **显示原文 / 显示译文** 重复切换。
4. 在译文态点 **导出**（仅 Android）→ 导出的文本含译文标题/简介/正文。

## 四、安装补丁到自己 fork

```bash
# 在你 fork 的 pixez-flutter 仓库根目录下：
# 1) 复制新增文件
mkdir -p lib/translate .github/workflows
cp <patch目录>/lib/translate/*.dart          lib/translate/
cp <patch目录>/.github/workflows/*.yml        .github/workflows/
# 2) 替换改动文件（已加 [PIXEZ-TRANSLATE-PATCH] 标记）
cp <patch目录>/lib/page/novel/viewer/novel_store.dart   lib/page/novel/viewer/
cp <patch目录>/lib/page/novel/viewer/novel_viewer.dart  lib/page/novel/viewer/
# 3) 重新生成 mobx 代码（novel_store.dart 改了 @observable / @action）
dart run build_runner build --delete-conflicting-outputs
git add -A && git commit -m "feat(novel): AI/MT translate patch"
git push
```

## 五、编译 APK

> 你电脑上没有编译环境，因此推荐用 GitHub Actions 在云端编译——
> 完全不用在你机器上装任何东西。

push 后到仓库 **Actions** 选项卡：

- 上游分支 `master`：每 push 自动触发；
- 也可手动：**Build Novel Translate APK** → Run workflow。

约 15–25 分钟后，在该运行结果页底部 Artifacts 里下载 `pixez-novel-translate-apk`，即为 `app-release.apk`。

### 为什么需要 Rust 工具链？

项目用了 `rhttp`（Rust 写的 HTTP 客户端，经 FFI 注入），路径见 `pubspec.yaml`：
`rhttp: path: ./plugins/rhttp/rhttp`。它通过 `cargokit` 在 Gradle 编译阶段把 Rust 代码交叉编译成 `.so`，目标平台包括 `aarch64 / armv7 / i686 / x86_64`。所以 workflow 里需要：Rust 工具链 + 4 个 android target + 固定版本 NDK（`ANDROID_NDK_HOME` 配好给 cargokit）。

### NDK 版本

工作流写死用 `27.0.12077973`。如果 Actions 报错说该版本不存在，改成 runner 上 `sdkmanager --list | grep ndk` 中最新的那个 LTS 版本即可（cargokit 只认 `ANDROID_NDK_HOME` 这一环境变量，对版本不挑剔）。

### Flutter SDK 版本选择

工作流用 `subosito/flutter-action@v2` 拉 stable 频道。若上游锁了某个 Flutter 版本（如 `.fvmrc` / `pubspec.yaml` 的 `environment.sdk`），可在 workflow 的 `flutter-action` 步骤里把 `channel: stable` 换成 `flutter-version: '<版本号>'`。本补丁当前的 `environment.sdk: ">=3.10.0"`，stable 即可满足。

## 六、上游同步策略

每次上游更新后：

```bash
git fetch upstream
git merge upstream/master      # 99% 概率自动成功
# 若 novel_viewer.dart / novel_store.dart 有冲突：
#   全部保留 [PIXEZ-TRANSLATE-PATCH] 段，其余采用上游版本
dart run build_runner build --delete-conflicting-outputs
git push
# → Actions 自动出新 APK，无需本机编译
```

由于补丁**不改 pubspec 依赖**，且所有 Dart 改动都集中在小说 viewer 两个文件 + 一个独立 `lib/translate/` 子目录，冲突极少会出现。

## 七、隐私与安全说明

- API Key 保存在本地 `shared_preferences`，不随导出文件外泄，不上传任何第三方。
- 翻译请求由 App 直接发往你配置的翻译服务端点；PixEz 的鉴权拦截器（`apiClient`）**不参与**翻译请求——`TranslateService` 用一个临时 `Dio()` 实例发起独立的 HTTPS 请求。
- 若用本地 Ollama：URL 填 `http://127.0.0.1:11434/v1/chat/completions`，Key 可空。

## 八、未来可选改进

- 复用已译结果（同篇小说不重复请求）：集合在 `NovelStore.translatedBody` 上即可天然做到（同一实例生命周期内不重译）。
- 增量翻译/分页渲染：当译文非常长时，按 `NovelSpansData` 段落逐段异步触发翻译。
- 加 Azure region 单独字段而非复用"模型"输入框（当前为最小改造，避免新增 prefs 字段数）。