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

  /// 逐块累积的 partial 译文正文（每块完成立即更新，不等全部完成）
  @observable
  String? partialTranslatedBody;

  /// 已完成翻译的块数（translateLarge 内部 chunk）
  @observable
  int translatedParagraphCount = 0;

  /// 总块数
  @observable
  int totalNormalParagraphs = 0;

  /// 触发整篇小说翻译。onProgress 每块完成回调 → UI 刷新。
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

      // 2. 术语表（可选，仅 AI 模式）
      String? glossary;
      if (cfg.useGlossary && cfg.provider == TranslateProvider.openai) {
        glossary = await TranslateService.extractGlossary(
            cfg, novelTextResponse!.text);
      }

      // 3. 整篇正文一次翻译，按块报告进度（translateLarge 内部自动切块）
      // 3. 整篇正文一次翻译，每块完成立即拼 partial translatedSpans
      final textToSend = glossary != null
          ? '术语表（请保持一致）：$glossary\n\n${novelTextResponse!.text}'
          : novelTextResponse!.text;
      final translatedText = await TranslateService.translateLarge(
        cfg, textToSend,
        onChunkProgress: (done, total, accumulated) {
          runInAction(() {
            translatedParagraphCount = done;
            totalNormalParagraphs = total;
            partialTranslatedBody = accumulated;
          });
          // 异步构建 partial translatedSpans（不阻塞块间进度）
          _buildPartialSpans(accumulated);
          onProgress?.call();
        },
      );

      // 4. 临时借原对象改 text → buildSpans → 还原
      final origText = novelTextResponse!.text;
      novelTextResponse!.text = translatedText;
      try {
        translatedSpans =
            await compute(buildSpans, novelTextResponse!);
      } finally {
        novelTextResponse!.text = origText;
      }
      runInAction(() => translating = false);
      return true;
    } catch (e) {
      runInAction(() {
        translateError = e.toString();
        translating = false;
      });
      return false;
    }
  }
  }

  /// 每块翻完异步构建 partial translatedSpans（不等全部完成即可看到译文）。
  Future<void> _buildPartialSpans(String partialText) async {
    try {
      final origText = novelTextResponse!.text;
      novelTextResponse!.text = partialText;
      try {
        translatedSpans =
            await compute(buildSpans, novelTextResponse!);
      } finally {
        novelTextResponse!.text = origText;
      }
    } catch (_) {
      // partial 构建失败无所谓，下一块会覆盖
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
