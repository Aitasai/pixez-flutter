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
  String apiUrl;
  String apiKey;
  String model;
  String targetLang;
  String systemPrompt;
  int maxConcurrency;       // 并行翻译段数 (1-10，默认 5)
  bool useGlossary;          // 是否启用术语表
  int glossaryBatchSize;     // 每批合并多少自然段 (2-20，默认 5)

  TranslateConfig({
    required this.provider,
    required this.apiUrl,
    required this.apiKey,
    required this.model,
    required this.targetLang,
    required this.systemPrompt,
    required this.maxConcurrency,
    required this.useGlossary,
    required this.glossaryBatchSize,
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
      maxConcurrency: 5,
      useGlossary: false,
      glossaryBatchSize: 5,
    );
  }

  // ---- 持久化（shared_preferences）----
  static const _kProvider = 'tr_provider';
  static const _kApiUrl = 'tr_api_url';
  static const _kApiKey = 'tr_api_key';
  static const _kModel = 'tr_model';
  static const _kTarget = 'tr_target_lang';
  static const _kSystem = 'tr_system_prompt';
  static const _kConcur = 'tr_max_concur';
  static const _kUseGloss = 'tr_use_gloss';
  static const _kGlossBatch = 'tr_gloss_batch';

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kProvider, provider.index);
    await p.setString(_kApiUrl, apiUrl);
    await p.setString(_kApiKey, apiKey);
    await p.setString(_kModel, model);
    await p.setString(_kTarget, targetLang);
    await p.setString(_kSystem, systemPrompt);
    await p.setInt(_kConcur, maxConcurrency);
    await p.setBool(_kUseGloss, useGlossary);
    await p.setInt(_kGlossBatch, glossaryBatchSize);
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
      maxConcurrency: p.getInt(_kConcur) ?? 5,
      useGlossary: p.getBool(_kUseGloss) ?? false,
      glossaryBatchSize: p.getInt(_kGlossBatch) ?? 5,
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

  /// 从全文提取术语表（人名/地名/关键名词 → 中文翻译）。
  /// 返回 JSON String 如 {"名前":"名字","東京":"东京"}，失败返回 null。
  static Future<String?> extractGlossary(TranslateConfig cfg, String fullText) async {
    if (cfg.provider != TranslateProvider.openai) return null;
    final prompt = '请从以下日文小说全文提取所有专有名词（人名、地名、'
        '组织名、关键术语），输出 JSON 对象，键为日文原文，值为中文翻译。'
        '只输出 JSON，不要额外说明。\n\n$fullText';
    try {
      final result = await _translateOpenAI(cfg, prompt);
      final start = result.indexOf('{');
      final end = result.lastIndexOf('}');
      if (start >= 0 && end > start) {
        return result.substring(start, end + 1);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 流式翻译：一次 API 请求，解析 SSE 流，每当 [SEG N] 段落完整时回调。
  /// 返回完整译文。仅 OpenAI 兼容 API 支持。
  static Future<String> translateStreaming(
    TranslateConfig cfg,
    String bodyText, {
    void Function(int paraIdx, String translated)? onParagraph,
    void Function(int done, int total)? onProgress,
  }) async {
    if (cfg.provider != TranslateProvider.openai) {
      return translateLarge(cfg, bodyText);
    }
    // 1. 按 \\n\\n 拆段并标注 [SEG N]
    final rawParas = bodyText
        .split(RegExp(r'\n{2,}'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final marked = <String>[];
    final markerMap = <String>[];  // for restore later
    for (int i = 0; i < rawParas.length; i++) {
      final local = <String>[];
      final ph = _placeholderMarkers(rawParas[i], local);
      markerMap.addAll(local);
      marked.add('[SEG${i + 1}]\n$ph');
    }
    final combined = marked.join('\n\n');

    // 2. 发流式请求
    final url = cfg.apiUrl.isEmpty ? cfg.defaultApiUrl : cfg.apiUrl;
    final dio = Dio();
    final resp = await dio.post<dynamic>(
      url,
      data: jsonEncode({
        'model': cfg.model,
        'temperature': 0.3,
        'stream': true,
        'messages': [
          {'role': 'system', 'content': cfg.systemPrompt},
          {'role': 'user', 'content': combined},
        ],
      }),
      options: Options(
        contentType: Headers.jsonContentType,
        headers: {'Authorization': 'Bearer ${cfg.apiKey}'},
        responseType: ResponseType.stream,
      ),
    );

    // 3. 解析 SSE 流
    final stream = resp.data.stream as Stream<List<int>>;
    final acc = StringBuffer();
    var lineBuf = '';
    var lastDone = 0;
    final total = rawParas.length;

    await for (final chunk in stream) {
      lineBuf += utf8.decode(chunk, allowMalformed: true);
      while (lineBuf.contains('\n')) {
        final nl = lineBuf.indexOf('\n');
        final line = lineBuf.substring(0, nl).trim();
        lineBuf = lineBuf.substring(nl + 1);
        if (line.startsWith('data: ') && line != 'data: [DONE]') {
          try {
            final data = jsonDecode(line.substring(6));
            final delta = data['choices']?[0]?['delta']?['content'];
            if (delta != null && delta is String) acc.write(delta);
          } catch (_) {}
        }
      }
      // 检查是否有新段落完整
      final full = _restoreMarkers(acc.toString(), markerMap);
      final segs = full.split(RegExp(r'\[SEG\d+\]'));
      final doneNow = segs.length - 1; // segs[0] is empty before first marker
      if (doneNow > lastDone) {
        for (int i = lastDone; i < doneNow && i < total; i++) {
          final t = segs.length > i + 1 ? segs[i + 1].trim() : '';
          if (t.isNotEmpty) onParagraph?.call(i, t);
        }
        lastDone = doneNow;
        onProgress?.call(doneNow.clamp(0, total), total);
      }
    }
    return _restoreMarkers(acc.toString(), markerMap);
  }

  /// 翻译任意长文本：占位化 → 分块 → 逐块翻译 → 还原标记。
  static Future<String> translateLarge(
    TranslateConfig cfg,
    String text, {
    int maxChunk = 1800,
    void Function(int done, int total, String accumulatedText)? onChunkProgress,
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
    final totalNonEmpty = chunks.where((c) => c.trim().isNotEmpty).length;
    var done = 0;
    for (final c in chunks) {
      if (c.trim().isEmpty) {
        out.add(c);
        continue;
      }
      out.add(await _translateSingle(cfg, c));
      done++;
      final partial = _restoreMarkers(out.join('\n'), markers);
      onChunkProgress?.call(done, totalNonEmpty, partial);
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