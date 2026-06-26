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

  // [PIXEZ-TRANSLATE-PATCH] ADD BEGIN —— 翻译状态（逐段翻译）
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

  /// 已完成翻译的段数（type == 'normal'）
  @observable
  int translatedParagraphCount = 0;

  /// 可翻译段落总数
  @observable
  int totalNormalParagraphs = 0;

  /// 当前正在翻译的段索引（-1 表示空闲）
  @observable
  int translatingParagraphIndex = -1;

  final Map<int, String> _paragraphTranslations = {};
  final Map<int, String> _paragraphErrors = {};

  /// 给定段索引是否有译文
  String? translatedTextForIdx(int idx) => _paragraphTranslations[idx];

  /// 给定段索引的错误
  String? errorForIdx(int idx) => _paragraphErrors[idx];

  /// 按双换行 \\n\\n 拆分文本成子段（一万字小说也不该只有 5 段）。
  static List<String> _splitSpanText(String text) {
    return text
        .split(RegExp(r'\n{2,}'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// 触发整篇小说翻译。
  /// 标题/简介即时翻译，正文按 \\n\\n 拆成自然段落，
  /// 3 路并行翻译，每完成一段立即刷新 UI（runInAction），
  /// 所有段完成后拼接 full body → 重建 translatedSpans。
  Future<bool> doTranslate() async {
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

      // 2. 按 \\n\\n 拆自然段: List<(spanIdx, subText)>
      final allSpans = spans;
      final subParas = <(int, String)>[];
      for (int i = 0; i < allSpans.length; i++) {
        if (allSpans[i].type == NovelSpansType.normal) {
          for (final p in _splitSpanText(allSpans[i].text)) {
            subParas.add((i, p));
          }
        }
      }
      runInAction(() => totalNormalParagraphs = subParas.length);

      // 3. 并行 3 路翻译子段
      for (int i = 0; i < subParas.length; i += 3) {
        final end = (i + 3).clamp(0, subParas.length);
        final batch = subParas.sublist(i, end);
        await Future.wait(
          batch.map((s) => _translateSub(s.$1, s.$2, cfg)),
        );
      }

      // 4. 拼接 full body → 临时借原对象改 text → buildSpans → 还原
      final buf = StringBuffer();
      for (int i = 0; i < allSpans.length; i++) {
        buf.write(_paragraphTranslations[i] ?? allSpans[i].text);
      }
      final origText = novelTextResponse!.text;
      novelTextResponse!.text = buf.toString();
      try {
        translatedSpans =
            await compute(buildSpans, novelTextResponse!);
      } finally {
        novelTextResponse!.text = origText;
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

  /// 翻译一个子段，完成后用 runInAction 立即更新 UI。
  Future<void> _translateSub(int spanIdx, String subText, TranslateConfig cfg) async {
    runInAction(() => translatingParagraphIndex = spanIdx);
    try {
      final translated = await TranslateService.translateLarge(cfg, subText);
      runInAction(() {
        final prev = _paragraphTranslations[spanIdx] ?? '';
        _paragraphTranslations[spanIdx] =
            prev.isEmpty ? translated : '$prev\n\n$translated';
        translatedParagraphCount++;
        translatingParagraphIndex = -1;
      });
    } catch (e) {
      runInAction(() {
        _paragraphErrors[spanIdx] =
            (_paragraphErrors[spanIdx] ?? '') + '${e.toString()}\n';
        translatedParagraphCount++;
        translatingParagraphIndex = -1;
      });
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
