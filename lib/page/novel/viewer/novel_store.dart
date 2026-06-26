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

  /// 触发整篇小说翻译（标题/简介即时翻译，正文逐段翻译并报告进度）。
  @action
  Future<bool> doTranslate() async {
    if (novelTextResponse == null || novel == null) return false;
    final cfg = await TranslateConfig.load();
    if (cfg.provider == TranslateProvider.none) {
      translateError = '未配置翻译服务';
      return false;
    }
    translating = true;
    translateError = null;
    _paragraphTranslations.clear();
    _paragraphErrors.clear();
    translatedParagraphCount = 0;
    translatedSpans = [];
    totalNormalParagraphs = 0;
    try {
      // 1. 标题 & 简介（即时，量小）
      translatedTitle =
          await TranslateService.translateLarge(cfg, novel!.title);
      final cap = (novel!.caption ?? '').toString();
      translatedCaption =
          cap.isEmpty ? '' : await TranslateService.translateLarge(cfg, cap);

      // 2. 统计 normal 段落
      final allSpans = spans;
      final normalIdxList = <int>[];
      for (int i = 0; i < allSpans.length; i++) {
        if (allSpans[i].type == 'normal') {
          normalIdxList.add(i);
        }
      }
      totalNormalParagraphs = normalIdxList.length;

      // 3. 逐段翻译
      for (int i = 0; i < normalIdxList.length; i++) {
        final idx = normalIdxList[i];
        translatingParagraphIndex = idx;
        try {
          final text = allSpans[idx].text;
          final translated =
              await TranslateService.translateLarge(cfg, text);
          _paragraphTranslations[idx] = translated;
          translatedParagraphCount++;
        } catch (e) {
          _paragraphErrors[idx] = e.toString();
        }
      }

      // 4. 用段落级译文重建全文 → 生成 translatedSpans
      final buf = StringBuffer();
      for (int i = 0; i < allSpans.length; i++) {
        if (_paragraphTranslations.containsKey(i)) {
          buf.write(_paragraphTranslations[i]);
        } else {
          buf.write(allSpans[i].text);
        }
      }
      final translatedResp =
          NovelWebResponse.fromJson(novelTextResponse!.toJson());
      translatedResp.text = buf.toString();
      translatedSpans = await compute(buildSpans, translatedResp);
      return translatedParagraphCount > 0;
    } catch (e) {
      translateError = e.toString();
      return false;
    } finally {
      translating = false;
      translatingParagraphIndex = -1;
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
