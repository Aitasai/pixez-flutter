// 小说 AI 翻译服务 —— 方案 A (OpenAI 兼容) + 方案 B (Google / 微软)
//
// 设计要点：
//  - 不引入额外依赖：HTTP 用项目已有的 dio（用全新的 Dio 实例，
//    不走 apiClient，避免 Pixiv 鉴权拦截器干扰翻译 API），
//    配置持久化用 shared_preferences（项目已依赖，userSetting 即基于它）。
//  - 标记占位化：Pixiv 小说正文含 [newpage] [pixivimage:1-2] [chapter:xx]
//    [uploadedimage:..] [[jumpuri:..]] [[rb:..]] 等标记。翻译前用低频
//    Unicode ‹n› 占位，翻译后还原，保证译文保留与原文一致的标记结构，
//    从而复用 NovelSpansGenerator 的解析（图片/分页在译文里也能正常显示）。
//  - 长文分块：按行累加至 maxChunk 字符后单独翻译再拼接，绕过各家 API
//    的单次长度上限并兼顾费用/上下文窗口。

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 支持的翻译提供方。
enum TranslateProvider { none, openai, google, microsoft }

/// 翻译配置。一份即可：开机加载一次缓存内存，改动后写回磁盘。
class TranslateConfig {
  TranslateProvider provider;
  String apiUrl; // OpenAI 兼容端点；Google/Microsoft 端点（默认即可）
  String apiKey;
  String model; // 仅 OpenAI 兼容方案需要
  String targetLang; // 形如 zh-CN / zh-Hans / en
  String systemPrompt; // 仅 OpenAI 兼容方案用到

  TranslateConfig({
    required this.provider,
    required this.apiUrl,
    required this.apiKey,
    required this.model,
    required this.targetLang,
    required this.systemPrompt,
  });

  factory TranslateConfig.defaults() {
    return TranslateConfig(
      provider: TranslateProvider.none,
      apiUrl: '',
      apiKey: '',
      model: 'gpt-3.5-turbo',
      targetLang: 'zh-CN',
      systemPrompt:
          '你是一名专业日文到中文的翻译。仅输出译文，不附加任何说明。'
          '务必原样保留文中所有形如「‹数字›」的占位符——不要改动、删除或翻译它们。',
    );
  }

  // ---- 持久化（shared_preferences）----
  static const _kProvider = 'tr_provider';
  static const _kApiUrl = 'tr_api_url';
  static const _kApiKey = 'tr_api_key';
  static const _kModel = 'tr_model';
  static const _kTarget = 'tr_target_lang';
  static const _kSystem = 'tr_system_prompt';

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kProvider, provider.index);
    await p.setString(_kApiUrl, apiUrl);
    await p.setString(_kApiKey, apiKey);
    await p.setString(_kModel, model);
    await p.setString(_kTarget, targetLang);
    await p.setString(_kSystem, systemPrompt);
  }

  static Future<TranslateConfig> load() async {
    final p = await SharedPreferences.getInstance();
    final idx = p.getInt(_kProvider) ?? 0;
    return TranslateConfig(
      provider: TranslateProvider.values[idx.clamp(0, TranslateProvider.values.length - 1)],
      apiUrl: p.getString(_kApiUrl) ?? '',
      apiKey: p.getString(_kApiKey) ?? '',
      model: p.getString(_kModel) ?? 'gpt-3.5-turbo',
      targetLang: p.getString(_kTarget) ?? 'zh-CN',
      systemPrompt: p.getString(_kSystem) ??
          '你是一名专业日文到中文的翻译。仅输出译文，不附加任何说明。'
              '务必原样保留文中所有形如「‹数字›」的占位符——不要改动、删除或翻译它们。',
    );
  }

  /// 给设置页用：根据当前 provider 给出建议端点。
  String get defaultApiUrl {
    switch (provider) {
      case TranslateProvider.openai:
        return 'https://api.openai.com/v1/chat/completions';
      case TranslateProvider.google:
        return 'https://translation.googleapis.com/language/translate/v2';
      case TranslateProvider.microsoft:
        return 'https://api.cognitive.microsofttranslator.com/translate';
      case TranslateProvider.none:
        return '';
    }
  }
}

/// 翻译执行器。全部静态方法，无状态。
class TranslateService {
  static final RegExp _markerRegex = RegExp(
    r'\[\[jumpuri:.*?\]\]'          // [[jumpuri:标题 > url]]
    r'|\[\[rb:.*?\]\]'              // [[rb:汉字>假名]]
    r'|\[newpage\]'                 // 分页
    r'|\[chapter:[^\]]*\]'          // 章节标题
    r'|\[pixivimage:[^\]]*\]'       // 嵌入插画
    r'|\[uploadedimage:[^\]]*\]',   // 上传图片
    dotAll: true,
  );
  static final RegExp _placeholderRegex = RegExp(r'‹(\d+)›');

  /// 把正文里的 Pixiv 标记替换成 ‹n›，markers 记录原文供还原。
  static String _placeholderMarkers(String text, List<String> markers) {
    markers.clear();
    return text.replaceAllMapped(_markerRegex, (m) {
      markers.add(m[0]!);
      return '‹${markers.length - 1}›';
    });
  }

  /// 把译文中残留的占位符还原回标记。
  static String _restoreMarkers(String text, List<String> markers) {
    return text.replaceAllMapped(_placeholderRegex, (m) {
      final idx = int.tryParse(m[1]!);
      if (idx != null && idx >= 0 && idx < markers.length) {
        return markers[idx];
      }
      return m[0]!;
    });
  }

  /// 翻译任意长文本：占位化 → 分块 → 逐块翻译 → 还原标记。
  static Future<String> translateLarge(
    TranslateConfig cfg,
    String text, {
    int maxChunk = 1800,
  }) async {
    if (text.trim().isEmpty) return text;

    final markers = <String>[];
    final ph = _placeholderMarkers(text, markers);

    // 按行聚合分块（每块字符数 <= maxChunk）。
    final lines = ph.split('\n');
    final chunks = <String>[];
    var cur = '';
    for (final l in lines) {
      final candidate = cur.isEmpty ? l : '$cur\n$l';
      if (candidate.length > maxChunk && cur.isNotEmpty) {
        chunks.add(cur);
        cur = l;
      } else {
        cur = candidate;
      }
    }
    if (cur.isNotEmpty) chunks.add(cur);

    final out = <String>[];
    for (final c in chunks) {
      if (c.trim().isEmpty) {
        out.add(c);
        continue;
      }
      out.add(await _translateSingle(cfg, c));
    }
    return _restoreMarkers(out.join('\n'), markers);
  }

  /// 单块翻译（已占位化、不会触达长度限制）。
  static Future<String> _translateSingle(TranslateConfig cfg, String chunk) async {
    switch (cfg.provider) {
      case TranslateProvider.none:
        throw StateError('未配置翻译服务');
      case TranslateProvider.openai:
        return _translateOpenAI(cfg, chunk);
      case TranslateProvider.google:
        return _translateGoogle(cfg, chunk);
      case TranslateProvider.microsoft:
        return _translateMicrosoft(cfg, chunk);
    }
  }

  // ---- 方案 A：OpenAI 兼容 ----
  // 同一套代码覆盖 OpenAI / DeepSeek / 智谱 / Moonshot / OpenRouter /
  // 本地 Ollama 等所有兼容 /v1/chat/completions 的服务。
  static Future<String> _translateOpenAI(TranslateConfig cfg, String chunk) async {
    final url = cfg.apiUrl.isEmpty ? cfg.defaultApiUrl : cfg.apiUrl;
    final dio = Dio();
    final resp = await dio.post<dynamic>(
      url,
      data: jsonEncode({
        'model': cfg.model,
        'temperature': 0.3,
        'messages': [
          {'role': 'system', 'content': cfg.systemPrompt},
          {'role': 'user', 'content': chunk},
        ],
      }),
      options: Options(
        contentType: Headers.jsonContentType,
        headers: {
          'Authorization': 'Bearer ${cfg.apiKey}',
        },
      ),
    );
    final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
    final choices = data['choices'];
    if (choices == null || choices is! List || choices.isEmpty) {
      throw Exception('OpenAI 兼容 API 未返回 choices');
    }
    final content = choices[0]['message']['content'];
    if (content is List) {
      // 部分服务（如 Ollama）内容可能为 List<{text}>
      return content.map((e) => e['text'] ?? '').join().trim();
    }
    return (content ?? '').toString().trim();
  }

  // ---- 方案 B-1：Google Translate v2 ----
  static Future<String> _translateGoogle(TranslateConfig cfg, String chunk) async {
    final url = cfg.apiUrl.isEmpty ? cfg.defaultApiUrl : cfg.apiUrl;
    final dio = Dio();
    final resp = await dio.post<dynamic>(
      url,
      data: {
        'q': chunk,
        'target': cfg.targetLang,
        'format': 'text',
        'key': cfg.apiKey,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
    final translations = data['data']?['translations'];
    if (translations == null || translations is! List || translations.isEmpty) {
      throw Exception('Google Translate 未返回 translations');
    }
    return (translations[0]['translatedText'] ?? '').toString().trim();
  }

  // ---- 方案 B-2：微软 Azure Translator ----
  static Future<String> _translateMicrosoft(TranslateConfig cfg, String chunk) async {
    final base = cfg.apiUrl.isEmpty ? cfg.defaultApiUrl : cfg.apiUrl;
    final dio = Dio();
    final resp = await dio.post<dynamic>(
      base,
      queryParameters: {'api-version': '3.0', 'to': cfg.targetLang},
      data: jsonEncode([
        {'Text': chunk},
      ]),
      options: Options(
        contentType: Headers.jsonContentType,
        headers: {
          'Ocp-Apim-Subscription-Key': cfg.apiKey,
          // 部分资源需要 region 头；保留一个可选项，留空则跳过。
          if (cfg.model.isNotEmpty) 'Ocp-Apim-Subscription-Region': cfg.model,
        },
      ),
    );
    final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
    if (data is! List || data.isEmpty) {
      throw Exception('Azure Translator 返回结构异常');
    }
    final list = data[0]['translations'];
    if (list == null || list is! List || list.isEmpty) {
      throw Exception('Azure Translator 未返回 translations');
    }
    return (list[0]['text'] ?? '').toString().trim();
  }
}