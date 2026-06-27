// 翻译设置页：选择翻译提供方、填 API 配置。
// 打开方式：小说页右上角"⋮"菜单 → "翻译设置"。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'translate_service.dart';

class TranslateSettingPage extends StatefulWidget {
  const TranslateSettingPage({Key? key}) : super(key: key);

  @override
  State<TranslateSettingPage> createState() => _TranslateSettingPageState();
}

class _TranslateSettingPageState extends State<TranslateSettingPage> {
  TranslateConfig? _cfg;
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _targetCtrl = TextEditingController();
  final _promptCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    TranslateConfig.load().then((c) {
      setState(() {
        _cfg = c;
        _urlCtrl.text = c.apiUrl;
        _keyCtrl.text = c.apiKey;
        _modelCtrl.text = c.model;
        _targetCtrl.text = c.targetLang;
        _promptCtrl.text = c.systemPrompt;
      });
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    _targetCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  void _applyProvider(TranslateProvider p) {
    final cfg = _cfg!;
    setState(() {
      cfg.provider = p;
      if (cfg.apiUrl.isEmpty) cfg.apiUrl = cfg.defaultApiUrl;
    });
  }

  Future<void> _save() async {
    final cfg = _cfg!;
    cfg.model = _modelCtrl.text.trim();
    cfg.model = (cfg.provider == TranslateProvider.microsoft && cfg.model.isEmpty)
        ? cfg.model
        : cfg.model;
    cfg.apiUrl = _urlCtrl.text.trim();
    cfg.apiKey = _keyCtrl.text.trim();
    cfg.targetLang = _targetCtrl.text.trim().isEmpty
        ? 'zh-CN'
        : _targetCtrl.text.trim();
    cfg.systemPrompt = _promptCtrl.text.trim().isEmpty
        ? TranslateConfig.defaults().systemPrompt
        : _promptCtrl.text.trim();
    await cfg.save();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存翻译配置')),
      );
    }
  }

  bool _testing = false;

  Future<void> _testTranslate() async {
    await _save();
    final cfg = _cfg!;
    setState(() => _testing = true);
    const testText = 'こんにちは、世界。これは翻訳テストです。';
    try {
      final result = await TranslateService.translateLarge(cfg, testText);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('翻译测试成功'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('原文：', style: TextStyle(fontWeight: FontWeight.bold)),
                const SelectableText(testText),
                const SizedBox(height: 12),
                const Text('译文：', style: TextStyle(fontWeight: FontWeight.bold)),
                SelectableText(result),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('翻译测试失败'),
          content: SelectableText(e.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscure = false,
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        maxLines: maxLines,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_cfg == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final cfg = _cfg!;
    final isAi = cfg.provider == TranslateProvider.openai;
    final isAiLikeProviders = const [
      TranslateProvider.openai,
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('翻译设置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: '保存',
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        children: [
          _section('翻译服务'),
          for (final p in TranslateProvider.values)
            RadioListTile<TranslateProvider>(
              value: p,
              groupValue: cfg.provider,
              onChanged: (v) {
                if (v != null) _applyProvider(v);
              },
              title: Text(_providerLabel(p)),
              subtitle: Text(_providerDesc(p)),
            ),

          if (cfg.provider != TranslateProvider.none) ...[
            _section('接口地址'),
            _field(
              controller: _urlCtrl,
              label: 'API URL',
              hint: cfg.defaultApiUrl.isEmpty ? '留空使用默认' : cfg.defaultApiUrl,
            ),

            _section('API Key'),
            _field(
              controller: _keyCtrl,
              label: 'API Key',
              hint: '留空则不携带鉴权（仅本地服务可用）',
              obscure: true,
            ),

            if (isAiLikeProviders.contains(cfg.provider)) ...[
              _section('模型'),
              _field(
                controller: _modelCtrl,
                label: '模型名',
                hint: 'gpt-3.5-turbo / deepseek-chat / glm-4 等任一开放接口模型',
              ),
              _section('系统提示词'),
              _field(
                controller: _promptCtrl,
                label: 'System Prompt',
                hint: '可自定义翻译风格',
                maxLines: 4,
              ),
            ],

            _section(isAi ? '目标语言' : '目标语言（如 zh-CN / zh-Hans / en）'),
            _field(
              controller: _targetCtrl,
              label: '目标语言',
              hint: '默认 zh-CN',
            ),

            _section('并行翻译数 (1-10)'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Expanded(
                  child: Slider(
                    value: cfg.maxConcurrency.toDouble(),
                    min: 1, max: 10, divisions: 9,
                    label: '${cfg.maxConcurrency}',
                    onChanged: (v) => setState(() => cfg.maxConcurrency = v.round()),
                  ),
                ),
                SizedBox(width: 8),
                Text('${cfg.maxConcurrency}',
                  style: Theme.of(context).textTheme.titleMedium),
              ]),
            ),

            if (isAi) ...[
              _section('术语表模式（减少人名/术语不一致）'),
              SwitchListTile(
                title: const Text('启用术语表'),
                subtitle: const Text('先全文抽取术语表，每段翻译时注入前缀以保持一致。'),
                value: cfg.useGlossary,
                onChanged: (v) => setState(() => cfg.useGlossary = v),
              ),
            ],
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '请先选择一个翻译服务。\n'
                '• AI 方案：OpenAI / DeepSeek / 智谱 / Moonshot / 本地 Ollama 等所有 '
                '/v1/chat/completions 兼容接口，填入 URL+Key+模型名即可。\n'
                '• 传统方案：Google Translate 或 微软 Azure Translator，仅需 API Key。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),

          ],

          const SizedBox(height: 24),
          if (cfg.provider != TranslateProvider.none) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.icon(
                icon: const Icon(Icons.save),
                label: const Text('保存配置'),
                onPressed: _save,
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton.icon(
                icon: _testing
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.science_outlined),
                label: Text(_testing ? '测试中…' : '测试翻译'),
                onPressed: _testing ? null : _testTranslate,
              ),
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  String _providerLabel(TranslateProvider p) {
    switch (p) {
      case TranslateProvider.none:
        return '未启用';
      case TranslateProvider.openai:
        return 'AI 翻译（OpenAI 兼容）';
      case TranslateProvider.google:
        return 'Google Translate';
      case TranslateProvider.microsoft:
        return '微软 Azure Translator';
    }
  }

  String _providerDesc(TranslateProvider p) {
    switch (p) {
      case TranslateProvider.none:
        return '关闭翻译功能';
      case TranslateProvider.openai:
        return 'OpenAI / DeepSeek / 智谱 / Moonshot / OpenRouter / Ollama 等';
      case TranslateProvider.google:
        return '需 Google Cloud Translation API Key';
      case TranslateProvider.microsoft:
        return '需 Azure 密钥；"模型"字段填资源 Region（如 eastasia）';
    }
  }
}