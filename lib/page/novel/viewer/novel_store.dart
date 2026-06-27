/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 *
 */

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:html/parser.dart';
import 'package:dio/dio.dart';
import 'package:mobx/mobx.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/novel_recom_response.dart';
import 'package:pixez/models/novel_viewer_persist.dart';
import 'package:pixez/models/novel_web_response.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/page/novel/viewer/image_text.dart';
import 'package:pixez/translate/translate_service.dart'; // [PIXEZ-TRANSLATE-PATCH] ADD
import 'package:flutter/widgets.dart';

part 'novel_store.g.dart';

class NovelStore = _NovelStoreBase with _$NovelStore;

abstract class _NovelStoreBase with Store {
  final int id;

  _NovelStoreBase(this.id, this.novel);

  @observable
  Novel? novel;
  @observable
  NovelWebResponse? novelTextResponse;
  @observable
  String? errorMessage;
  @observable
  bool positionBooked = false;

  @observable
  double bookedOffset = 0.0;
  @observable
  List<NovelSpansData> spans = [];


  // [PIXEZ-TRANSLATE-PATCH] ADD BEGIN —— 翻译状态（逐自然段翻译）
  @observable
  bool translating = false;
  @observable
  String? translatedTitle;
  @observable
  String? translatedCaption;
  @observable
  List<NovelSpansData> translatedSpans = [];
  @observable
  String? translateError;

  /// 已完成翻译的自然段数
  @observable
  int translatedParagraphCount = 0;

  /// 自然段总数
  @observable
  int totalNormalParagraphs = 0;

  /// 当前正在翻译的段索引（-1 = 空闲）
  @observable
  int translatingParagraphIndex = -1;

  final Map<int, String> _paragraphTranslations = {};
  final Map<int, String> _paragraphErrors = {};

  String? translatedTextForIdx(int idx) => _paragraphTranslations[idx];
  String? errorForIdx(int idx) => _paragraphErrors[idx];

  /// 按双换行 \n\n 拆自然段
  static List<String> _splitParagraphs(String text) {
    return text
        .split(RegExp(r'\n{2,}'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// 触发翻译：标题/简介 → 术语表 → 逐段并行翻译正文。
  Future<bool> doTranslate({void Function()? onProgress}) async {
    if (novelTextResponse == null || novel == null) return false;
    final cfg = await TranslateConfig.load();
    if (cfg.provider == TranslateProvider.none) {
      runInAction(() => translateError = '未配置翻译服务');
      return false;
    }
    runInAction(() {
      translating = true;
      translateError = null;
      _paragraphTranslations.clear();
      _paragraphErrors.clear();
      translatedParagraphCount = 0;
      translatedSpans = [];
      totalNormalParagraphs = 0;
    });
    try {
      // 1. 标题 & 简介
      translatedTitle =
          await TranslateService.translateLarge(cfg, novel!.title);
      final cap = (novel!.caption ?? '').toString();
      translatedCaption =
          cap.isEmpty ? '' : await TranslateService.translateLarge(cfg, cap);

      // 2. 术语表 → 注入 system prompt（每段请求都看到）
      String? glossary;
      if (cfg.useGlossary && cfg.provider == TranslateProvider.openai) {
        glossary = await TranslateService.extractGlossary(
            cfg, novelTextResponse!.text);
        if (glossary != null) {
          cfg.systemPrompt =
              '${cfg.systemPrompt}\n\n术语表（请保持一致）：$glossary';
        }
      }

      // 3. 按 \n\n 拆自然段，按 glossaryBatchSize 合并为批次
      final paras = _splitParagraphs(novelTextResponse!.text);
      final batchSize = cfg.glossaryBatchSize.clamp(1, 20);
      final batches = <(int, List<String>)>[];
      for (int i = 0; i < paras.length; i += batchSize) {
        final end = (i + batchSize).clamp(0, paras.length);
        batches.add((i, paras.sublist(i, end)));
      }
      final totalBatches = batches.length;
      runInAction(() => totalNormalParagraphs = totalBatches);

      // 4. 并发翻译批次
      final concurrency = cfg.maxConcurrency.clamp(1, 10);
      for (int i = 0; i < batches.length; i += concurrency) {
        final end = (i + concurrency).clamp(0, batches.length);
        final group = batches.sublist(i, end);
        await Future.wait(
          group.map((b) => _translateBatch(b.$1, b.$2, cfg)),
        );
        await _rebuildTranslatedSpans();
        onProgress?.call();
        await Future.delayed(const Duration(milliseconds: 30));
      }
      runInAction(() => translating = false);
      return translatedParagraphCount > 0;
    } catch (e) {
      runInAction(() {
        translateError = e.toString();
        translating = false;
      });
      return false;
    }
  }

  /// 翻译一个批次（N 个自然段合并为一次 API 调用，[SEG N] 标记切分）。
  Future<void> _translateBatch(int baseIdx, List<String> texts,
      TranslateConfig cfg) async {
    runInAction(() => translatingParagraphIndex = baseIdx);
    try {
      final buf = StringBuffer();
      for (int i = 0; i < texts.length; i++) {
        if (i > 0) buf.write('\n\n');
        buf.write('[SEG${baseIdx + i + 1}]\n${texts[i]}');
      }
      final combined = buf.toString();
      final translated = await TranslateService.translateLarge(cfg, combined);
      final parts = translated
          .split(RegExp(r'\[SEG\d+\]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      runInAction(() {
        for (int i = 0; i < texts.length && i < parts.length; i++) {
          _paragraphTranslations[baseIdx + i] = parts[i];
          translatedParagraphCount += texts.length;
        }
        translatingParagraphIndex = -1;
      });
    } catch (e) {
      runInAction(() {
        for (int i = 0; i < texts.length; i++) {
          _paragraphErrors[baseIdx + i] = e.toString();
        }
        translatedParagraphCount += texts.length;
        translatingParagraphIndex = -1;
      });
    }
  }

  /// 用当前已有段落译文重建 translatedSpans（不等全部完成）。
  Future<void> _rebuildTranslatedSpans() async {
    try {
      final buf = StringBuffer();
      final splits = _splitParagraphs(novelTextResponse!.text);
      for (int i = 0; i < splits.length; i++) {
        if (i > 0) buf.write('\n\n');
        buf.write(_paragraphTranslations[i] ?? splits[i]);
      }
      final origText = novelTextResponse!.text;
      novelTextResponse!.text = buf.toString();
      try {
        translatedSpans =
            await compute(buildSpans, novelTextResponse!);
      } finally {
        novelTextResponse!.text = origText;
      }
    } catch (_) {
      // partial rebuild 失败无所谓，下轮覆盖
    }
  }
  // [PIXEZ-TRANSLATE-PATCH] ADD END

  NovelViewerPersistProvider _novelViewerPersistProvider =
      NovelViewerPersistProvider();

  @action
  bookPosition(double offset) async {
    LPrinter.d("bookPosition $offset");
    await _novelViewerPersistProvider.open();
    await _novelViewerPersistProvider
        .insert(NovelViewerPersist(novelId: id, offset: offset));
    positionBooked = true;
  }

  @action
  deleteBookPosition() async {
    LPrinter.d("deleteBookPosition");
    await _novelViewerPersistProvider.open();
    await _novelViewerPersistProvider.delete(id);
    positionBooked = false;
  }

  @action
  Future<void> fetch() async {
    errorMessage = null;
    try {
      bookedOffset = 0.0;
      final response = await apiClient.webviewNovel(id);
      String json = _parseHtml(response.data)!;
      novelTextResponse = NovelWebResponse.fromJson(jsonDecode(json));
      spans = await compute(buildSpans, novelTextResponse!);
      if (novel == null) {
        Response response = await apiClient.getNovelDetail(id);
        novel = Novel.fromJson(response.data['novel']);
      }
      novelHistoryStore.insert(novel!);
      fetchOffset();
    } catch (e) {
      print(e);
      errorMessage = e.toString();
    }
  }

  String? _parseHtml(String html) {
    var document = parse(html);
    final scriptElement = document.querySelector('script')!;
    String scriptContent = scriptElement.innerHtml;
    final novelRegex = RegExp(r'novel: ({.*?}),\n\s*isOwnWork');
    final match = novelRegex.firstMatch(scriptContent);
    if (match != null) {
      final novelJsonString = match.group(1);
      return novelJsonString;
    }
    return null;
  }

  @action
  fetchOffset() async {
    try {
      await _novelViewerPersistProvider.open();
      final result = await _novelViewerPersistProvider.getNovelPersistById(id);
      if (result != null) {
        LPrinter.d("fetchOffset ${result.offset}");
        positionBooked = true;
        bookedOffset = result.offset;
      }
    } catch (e) {}
  }
}

class ComputeSpan {
  final BuildContext context;
  final NovelWebResponse webResponse;

  ComputeSpan(this.context, this.webResponse);
}

Future<List<NovelSpansData>> buildSpans(NovelWebResponse webResponse) {
  return Future.delayed(Duration(milliseconds: 100), () {
    NovelSpansGenerator novelSpansGenerator = NovelSpansGenerator();
    return novelSpansGenerator.buildSpans(webResponse);
  });
}
