import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:GitSync/api/ai_provider_validator.dart';
import 'package:GitSync/api/manager/git_manager.dart';
import 'package:GitSync/src/rust/api/git_manager.dart' as GitManagerRs;
import 'package:GitSync/api/ai_tools.dart';
import 'package:GitSync/api/ai_tools_file.dart';
import 'package:GitSync/api/ai_sensitive_path.dart';
import 'package:GitSync/api/manager/storage.dart';
import 'package:GitSync/global.dart';
import 'package:GitSync/constant/dimens.dart';
import 'package:GitSync/providers/riverpod_providers.dart';
import 'package:GitSync/type/ai_chat.dart';
import 'package:GitSync/ui/component/markdown_config.dart';
import 'package:GitSync/ui/dialog/base_alert_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

const _mono = TextStyle(fontFamily: "monospace", height: 1.6);

final _urlRegex = RegExp(r'(?:https?://|www\.)[^\s<>"]+', caseSensitive: false);

class AiFeaturesPage extends ConsumerStatefulWidget {
  const AiFeaturesPage({super.key});
  @override
  ConsumerState<AiFeaturesPage> createState() => _AiFeaturesPageState();
}

class _AiFeaturesPageState extends ConsumerState<AiFeaturesPage> {
  bool _initialized = false;
  String? _currentChatModel;
  String? _currentToolModel;
  String? _currentWandModel;
  String? _currentProvider;
  String _repoName = 'Repository';
  String? _branchName;
  int _changedFileCount = 0;
  List<(String, int)> _changedFiles = [];
  bool _hasDraft = false;
  bool _refreshingContext = false;

  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();

  Completer<bool>? _confirmationCompleter;
  AiTool? _pendingTool;

  @override
  void initState() {
    super.initState();
    _checkStoredApiKey();
    aiChatService.onConfirmationRequired = _onConfirmationRequired;
    aiChatService.switchToRepo();
    unawaited(_loadRepoContext());
  }

  @override
  void dispose() {
    if (_confirmationCompleter != null && !_confirmationCompleter!.isCompleted) {
      _confirmationCompleter!.complete(false);
    }
    _inputController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _checkStoredApiKey() async {
    final provider = await repoManager.getStringNullable(StorageKey.repoman_aiProvider);
    final apiKey = await repoManager.getStringNullable(StorageKey.repoman_aiApiKey);
    final chatModel = await repoManager.getStringNullable(StorageKey.repoman_aiChatModel);
    final toolModel = await repoManager.getStringNullable(StorageKey.repoman_aiToolModel);
    final wandModel = await repoManager.getStringNullable(StorageKey.repoman_aiWandModel);
    if (!mounted) return;
    if (provider != null && provider.isNotEmpty && apiKey != null && apiKey.isNotEmpty) {
      setState(() {
        _initialized = true;
        _currentChatModel = chatModel;
        _currentToolModel = toolModel;
        _currentWandModel = wandModel;
        _currentProvider = provider;
      });
    } else if (_initialized) {
      setState(() => _initialized = false);
    }
  }

  Future<bool> _onConfirmationRequired(AiTool tool, Map<String, dynamic> input) async {
    _confirmationCompleter = Completer<bool>();
    setState(() {
      _pendingTool = tool;
    });
    final result = await _confirmationCompleter!.future;
    setState(() {
      _pendingTool = null;
      _confirmationCompleter = null;
    });
    return result;
  }

  Future<void> _loadRepoContext() async {
    if (_refreshingContext) return;
    if (mounted) setState(() => _refreshingContext = true);
    try {
      final directory = await uiSettingsManager.getGitDirPath();
      if (directory == null) {
        if (mounted) setState(() { _repoName = 'No repository selected'; _branchName = null; _changedFileCount = 0; _changedFiles = []; });
        return;
      }
      final pieces = directory.$1.replaceAll('\\', '/').split('/').where((part) => part.isNotEmpty).toList();
      final branch = await GitManager.getBranchName();
      final changed = await GitManager.getUncommittedFilePaths();
      if (!mounted) return;
      setState(() {
        _repoName = pieces.isEmpty ? 'Repository' : pieces.last;
        _branchName = branch;
        _changedFileCount = changed.length;
        _changedFiles = changed;
      });
    } catch (_) {
      if (mounted) setState(() { _repoName = 'Repository'; _branchName = null; _changedFileCount = 0; _changedFiles = []; });
    } finally {
      if (mounted) setState(() => _refreshingContext = false);
    }
  }

  Future<void> _copyText(String text, String feedback) async {
    if (text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.selectionClick();
    Fluttertoast.showToast(msg: feedback, toastLength: Toast.LENGTH_SHORT);
  }

  void _sendMessage({Iterable<String>? contextPaths}) {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.selectionClick();
    _inputController.clear();
    if (mounted) setState(() => _hasDraft = false);
    aiChatService.sendMessage(text, contextPaths: contextPaths);
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) return _UninitializedPage(onSubscribe: () => _checkStoredApiKey());

    return Container(
      color: colours.primaryDark,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _AmbientBackdrop(),
          Column(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => _focusNode.unfocus(),
                  child: Stack(
                    children: [
                      ValueListenableBuilder<List<ChatMessage>>(
                        valueListenable: aiChatService.messages,
                        builder: (context, messages, _) {
                          return ValueListenableBuilder<String>(
                            valueListenable: aiChatService.streamingText,
                            builder: (context, streamingText, _) {
                              return ValueListenableBuilder<bool>(
                                valueListenable: aiChatService.isStreaming,
                                builder: (context, isStreaming, _) {
                                  final itemCount = messages.length +
                                      (streamingText.isNotEmpty ? 1 : 0) +
                                      (_pendingTool != null ? 1 : 0);

                                  if (messages.isEmpty && !isStreaming) return _emptyState();

                                  return ListView.builder(
                                    controller: _scrollController,
                                    reverse: true,
                                    padding: EdgeInsets.fromLTRB(spaceMD, spaceXL + spaceLG + spaceMD, spaceMD, spaceSM),
                                    itemCount: itemCount,
                                    itemBuilder: (context, reverseIndex) {
                                      final index = itemCount - 1 - reverseIndex;
                                      if (index < messages.length) return _buildMessage(messages[index]);

                                      final offset = index - messages.length;
                                      if (streamingText.isNotEmpty && offset == 0) {
                                        return Padding(
                                          padding: EdgeInsets.only(bottom: spaceXS),
                                          child: _responseStreaming(streamingText),
                                        );
                                      }
                                      if (_pendingTool != null) return _confirmationChip(_pendingTool!);
                                      return const SizedBox.shrink();
                                    },
                                  );
                                },
                              );
                            },
                          );
                        },
                      ),
                      Positioned(top: 0, left: 0, right: 0, child: _chatHeader()),
                    ],
                  ),
                ),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: aiChatService.error,
                builder: (context, error, _) {
                  if (error == null) return const SizedBox.shrink();
                  return Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(horizontal: spaceMD, vertical: spaceXS),
                    color: colours.primaryNegative.withValues(alpha: 0.15),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () async {
                              await Clipboard.setData(ClipboardData(text: error));
                              Fluttertoast.showToast(msg: 'Error copied to clipboard', toastLength: Toast.LENGTH_SHORT);
                            },
                            child: Text(
                              error,
                              style: _mono.merge(TextStyle(color: colours.primaryNegative, fontSize: textXS)),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => aiChatService.error.value = null,
                          child: Container(
                            constraints: BoxConstraints(minWidth: spaceXL, minHeight: spaceXL),
                            alignment: Alignment.center,
                            child: FaIcon(FontAwesomeIcons.xmark, color: colours.primaryNegative, size: textMD),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              _inputBar(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chatHeader() {
    return Container(
      padding: EdgeInsets.fromLTRB(spaceMD, spaceSM, spaceMD, spaceSM),
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [colours.secondaryDark.withValues(alpha: 0.94), colours.primaryDark.withValues(alpha: 0.98)]),
        border: Border(bottom: BorderSide(color: colours.tertiaryInfo.withValues(alpha: 0.12))),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 14, offset: Offset(0, 5))],
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            _PulsingBrandMark(size: 42),
            SizedBox(width: spaceSM),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Text('RepoSync', style: TextStyle(color: colours.primaryLight, fontSize: textMD, fontWeight: FontWeight.w800, letterSpacing: -0.25)),
                    SizedBox(width: spaceXXS),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: spaceXXS, vertical: 2),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [colours.tertiaryInfo, colours.primaryPositive]),
                        borderRadius: BorderRadius.all(cornerRadiusXS),
                      ),
                      child: Text('AI', style: TextStyle(color: colours.primaryDark, fontSize: textXXS, fontWeight: FontWeight.w900, height: 1.1)),
                    ),
                  ]),
                  SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(_repoName, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colours.secondaryLight, fontSize: textXS, fontWeight: FontWeight.w600)),
                      ),
                      if (_branchName != null && _branchName!.isNotEmpty) ...[
                        Padding(padding: EdgeInsets.symmetric(horizontal: spaceXXS), child: Text('·', style: TextStyle(color: colours.tertiaryLight))),
                        Flexible(
                          child: Text(_branchName!, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: _mono.merge(TextStyle(color: colours.tertiaryInfo, fontSize: textXXS))),
                        ),
                      ],
                      if (_changedFileCount > 0) ...[
                        Padding(padding: EdgeInsets.symmetric(horizontal: spaceXXS), child: Text('·', style: TextStyle(color: colours.tertiaryLight))),
                        Text('$_changedFileCount changed', style: TextStyle(color: colours.primaryWarning, fontSize: textXXS)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(width: spaceXS),
            Tooltip(
              message: 'AI provider and models',
              child: Material(
                color: colours.secondaryDark,
                borderRadius: BorderRadius.all(cornerRadiusMax),
                child: InkWell(
                  borderRadius: BorderRadius.all(cornerRadiusMax),
                  onTap: () => _showTokenDialog(context),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: spaceSM, vertical: spaceXS),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 7, height: 7, decoration: BoxDecoration(color: colours.primaryPositive, shape: BoxShape.circle,
                        boxShadow: [BoxShadow(color: colours.primaryPositive.withValues(alpha: 0.5), blurRadius: 7)])),
                      SizedBox(width: spaceXXS),
                      Text(_currentProvider ?? 'AI', style: TextStyle(color: colours.primaryLight, fontSize: textXS, fontWeight: FontWeight.bold)),
                      SizedBox(width: spaceXXS),
                      FaIcon(FontAwesomeIcons.chevronDown, color: colours.secondaryLight, size: textXXS),
                    ]),
                  ),
                ),
              ),
            ),
            SizedBox(width: spaceXXS),
            PopupMenuButton<String>(
              tooltip: 'Chat options',
              icon: FaIcon(FontAwesomeIcons.ellipsisVertical, color: colours.secondaryLight, size: textSM),
              onSelected: (value) {
                switch (value) {
                  case 'context':
                    unawaited(_showRepositoryContext());
                    break;
                  case 'history':
                    unawaited(_showChatHistory());
                    break;
                  case 'new':
                    unawaited(_startNewChat());
                    break;
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(value: 'context', child: _menuOption(FontAwesomeIcons.folderOpen, 'Repository context')),
                PopupMenuItem(value: 'history', child: _menuOption(FontAwesomeIcons.clockRotateLeft,
                  'Chat history (${aiChatService.conversationHistory.length})')),
                PopupMenuDivider(),
                PopupMenuItem(value: 'new', enabled: !aiChatService.isStreaming.value,
                  child: _menuOption(FontAwesomeIcons.plus, 'New conversation')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _menuOption(FaIconData icon, String label) {
    return Row(children: [
      FaIcon(icon, color: colours.tertiaryInfo, size: textSM),
      SizedBox(width: spaceSM),
      Text(label, style: TextStyle(color: colours.primaryLight, fontSize: textSM, fontWeight: FontWeight.w600)),
    ]);
  }

  Future<void> _startNewChat() async {
    if (aiChatService.isStreaming.value) return;
    final hadMessages = aiChatService.messages.value.isNotEmpty;
    await aiChatService.startNewConversation();
    if (hadMessages) Fluttertoast.showToast(msg: 'Conversation saved to history', toastLength: Toast.LENGTH_SHORT);
  }

  Future<void> _showChatHistory() async {
    final history = aiChatService.conversationHistory;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.45,
        maxChildSize: 0.92,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [colours.secondaryDark, colours.primaryDark]),
            borderRadius: BorderRadius.vertical(top: Radius.circular(cornerRadiusLG.x)),
            border: Border.all(color: colours.tertiaryInfo.withValues(alpha: 0.2)),
          ),
          child: Column(children: [
            SizedBox(height: spaceSM),
            Container(width: 42, height: 4, decoration: BoxDecoration(color: colours.tertiaryLight.withValues(alpha: 0.55),
              borderRadius: BorderRadius.all(cornerRadiusMax))),
            Padding(
              padding: EdgeInsets.fromLTRB(spaceMD, spaceSM, spaceXS, spaceSM),
              child: Row(children: [
                Container(width: 40, height: 40,
                  decoration: BoxDecoration(gradient: LinearGradient(colors: [colours.tertiaryInfo, colours.primaryPositive]),
                    borderRadius: BorderRadius.all(cornerRadiusSM)),
                  child: Center(child: Icon(FontAwesomeIcons.clockRotateLeft, color: colours.primaryDark, size: textSM))),
                SizedBox(width: spaceSM),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Chat history', style: TextStyle(color: colours.primaryLight, fontSize: textLG, fontWeight: FontWeight.w900)),
                  SizedBox(height: 2),
                  Text('Saved on this device · ${history.length} conversations',
                    style: TextStyle(color: colours.secondaryLight, fontSize: textXXS)),
                ])),
                IconButton(
                  tooltip: 'Start a new conversation',
                  onPressed: () async {
                    Navigator.of(sheetContext).pop();
                    await _startNewChat();
                  },
                  icon: FaIcon(FontAwesomeIcons.plus, color: colours.tertiaryInfo, size: textSM),
                ),
                IconButton(tooltip: 'Close', onPressed: () => Navigator.of(sheetContext).pop(),
                  icon: FaIcon(FontAwesomeIcons.xmark, color: colours.secondaryLight, size: textSM)),
              ]),
            ),
            Expanded(
              child: history.isEmpty
                  ? ListView(controller: scrollController, children: [SizedBox(height: spaceXL), _historyEmptyState()])
                  : ListView.separated(
                      controller: scrollController,
                      padding: EdgeInsets.fromLTRB(spaceMD, 0, spaceMD, spaceLG),
                      itemCount: history.length,
                      separatorBuilder: (context, index) => SizedBox(height: spaceXS),
                      itemBuilder: (context, index) {
                        final session = history[index];
                        return Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.all(cornerRadiusSM),
                          child: InkWell(
                            borderRadius: BorderRadius.all(cornerRadiusSM),
                            onTap: () async {
                              final restored = await aiChatService.restoreConversation(session.id);
                              if (restored && sheetContext.mounted) Navigator.of(sheetContext).pop();
                            },
                            child: Container(
                              padding: EdgeInsets.all(spaceSM),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                                  colors: [colours.tertiaryDark.withValues(alpha: 0.62), colours.secondaryDark.withValues(alpha: 0.72)]),
                                borderRadius: BorderRadius.all(cornerRadiusSM),
                                border: Border.all(color: colours.tertiaryInfo.withValues(alpha: 0.12)),
                              ),
                              child: Row(children: [
                                Container(width: 38, height: 38,
                                  decoration: BoxDecoration(color: colours.tertiaryInfo.withValues(alpha: 0.1), shape: BoxShape.circle),
                                  child: Center(child: FaIcon(FontAwesomeIcons.message, color: colours.tertiaryInfo, size: textSM))),
                                SizedBox(width: spaceSM),
                                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(session.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: colours.primaryLight, fontSize: textSM, fontWeight: FontWeight.w700, height: 1.2)),
                                  SizedBox(height: spaceXXS),
                                  Text('${session.messageCount} messages · ${_historyAge(session.updatedAt)}',
                                    style: TextStyle(color: colours.secondaryLight, fontSize: textXXS)),
                                ])),
                                SizedBox(width: spaceXS),
                                FaIcon(FontAwesomeIcons.arrowRight, color: colours.tertiaryLight, size: textXS),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _historyEmptyState() {
    return Center(child: Padding(padding: EdgeInsets.all(spaceLG), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 60, height: 60,
        decoration: BoxDecoration(gradient: LinearGradient(colors: [colours.tertiaryInfo.withValues(alpha: 0.15), colours.primaryPositive.withValues(alpha: 0.08)]),
          shape: BoxShape.circle, border: Border.all(color: colours.tertiaryInfo.withValues(alpha: 0.16))),
        child: Center(child: FaIcon(FontAwesomeIcons.comments, color: colours.tertiaryInfo, size: textLG))),
      SizedBox(height: spaceSM),
      Text('Your saved chats will appear here', style: TextStyle(color: colours.primaryLight, fontSize: textMD, fontWeight: FontWeight.w800)),
      SizedBox(height: spaceXXS),
      Text('Start a new conversation to save the current one and make room for a fresh thread.',
        textAlign: TextAlign.center, style: TextStyle(color: colours.secondaryLight, fontSize: textXS, height: 1.4)),
    ])));
  }

  String _historyAge(DateTime date) {
    final days = DateTime.now().difference(date).inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return 'Yesterday';
    if (days < 7) return '$days days ago';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Future<void> _showRepositoryContext() async {
    await _loadRepoContext();
    if (!mounted) return;

    var query = '';
    final selectedPaths = <String>{};
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.78,
        minChildSize: 0.48,
        maxChildSize: 0.94,
        builder: (context, scrollController) => StatefulBuilder(
          builder: (context, setSheetState) {
            final files = _changedFiles.where((file) => file.$1.toLowerCase().contains(query.toLowerCase())).toList();
            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                  colors: [colours.secondaryDark, colours.primaryDark]),
                borderRadius: BorderRadius.vertical(top: Radius.circular(cornerRadiusLG.x)),
                border: Border.all(color: colours.tertiaryInfo.withValues(alpha: 0.2)),
                boxShadow: [BoxShadow(color: colours.tertiaryInfo.withValues(alpha: 0.08), blurRadius: 32, offset: Offset(0, -6))],
              ),
              child: Column(
                children: [
                  SizedBox(height: spaceSM),
                  Container(width: 42, height: 4, decoration: BoxDecoration(color: colours.tertiaryLight.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.all(cornerRadiusMax))),
                  Padding(
                    padding: EdgeInsets.fromLTRB(spaceMD, spaceSM, spaceSM, spaceSM),
                    child: Row(
                      children: [
                        _PulsingBrandMark(size: 46),
                        SizedBox(width: spaceSM),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Repository context', style: TextStyle(color: colours.primaryLight, fontSize: textLG, fontWeight: FontWeight.w900)),
                          SizedBox(height: 2),
                          Text(_repoName, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colours.secondaryLight, fontSize: textXS, fontWeight: FontWeight.w600)),
                        ])),
                        IconButton(
                          tooltip: 'Refresh repository details',
                          onPressed: _refreshingContext ? null : () async {
                            await _loadRepoContext();
                            if (sheetContext.mounted) setSheetState(() {});
                          },
                          icon: _refreshingContext
                              ? SizedBox(width: textSM, height: textSM, child: CircularProgressIndicator(strokeWidth: 2, color: colours.tertiaryInfo))
                              : FaIcon(FontAwesomeIcons.arrowsRotate, color: colours.secondaryLight, size: textSM),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          icon: FaIcon(FontAwesomeIcons.xmark, color: colours.secondaryLight, size: textSM),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: spaceMD),
                    child: Wrap(spacing: spaceXS, runSpacing: spaceXS, children: [
                      _contextPill(FontAwesomeIcons.codeBranch, _branchName ?? 'No branch', colours.primaryPositive),
                      _contextPill(FontAwesomeIcons.fileLines, '${_changedFiles.length} changed files',
                        _changedFiles.isEmpty ? colours.primaryPositive : colours.primaryWarning),
                      _contextPill(FontAwesomeIcons.robot, _currentProvider ?? 'AI provider', colours.tertiaryInfo),
                    ]),
                  ),
                  SizedBox(height: spaceMD),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: spaceMD),
                    child: Row(children: [
                      Expanded(child: Text('WORKING TREE', style: TextStyle(color: colours.tertiaryInfo,
                        fontSize: textXXS, fontWeight: FontWeight.w900, letterSpacing: 1.2))),
                      Text('${files.length} ${query.isEmpty ? 'files' : 'results'}',
                        style: TextStyle(color: colours.secondaryLight, fontSize: textXXS, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                  SizedBox(height: spaceXS),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: spaceMD),
                    child: TextField(
                      onChanged: (value) => setSheetState(() => query = value.trim()),
                      style: TextStyle(color: colours.primaryLight, fontSize: textSM),
                      decoration: InputDecoration(
                        hintText: 'Filter changed file paths…',
                        hintStyle: TextStyle(color: colours.secondaryLight, fontSize: textSM),
                        prefixIcon: FaIcon(FontAwesomeIcons.magnifyingGlass, color: colours.secondaryLight, size: textXS),
                        filled: true,
                        fillColor: colours.primaryDark.withValues(alpha: 0.5),
                        contentPadding: EdgeInsets.symmetric(horizontal: spaceSM, vertical: spaceSM),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.all(cornerRadiusSM),
                          borderSide: BorderSide(color: colours.tertiaryDark)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.all(cornerRadiusSM),
                          borderSide: BorderSide(color: colours.tertiaryInfo.withValues(alpha: 0.7))),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(spaceMD, spaceXS, spaceMD, 0),
                    child: Row(children: [
                      FaIcon(FontAwesomeIcons.circleInfo, color: colours.tertiaryLight, size: textXXS),
                      SizedBox(width: spaceXXS),
                      Expanded(child: Text('Tap a file for its diff · Select paths for a scoped AI review',
                        style: TextStyle(color: colours.secondaryLight, fontSize: textXXS))),
                    ]),
                  ),
                  SizedBox(height: spaceSM),
                  Expanded(
                    child: files.isEmpty
                        ? ListView(
                            controller: scrollController,
                            physics: AlwaysScrollableScrollPhysics(),
                            children: [SizedBox(height: spaceXL), _repositoryContextEmptyState(query)],
                          )
                        : ListView.separated(
                            controller: scrollController,
                            padding: EdgeInsets.fromLTRB(spaceMD, 0, spaceMD, spaceLG),
                            itemCount: files.length,
                            separatorBuilder: (context, index) => SizedBox(height: spaceXS),
                            itemBuilder: (context, index) {
                              final file = files[index];
                              return _changedFileTile(
                                file,
                                selected: selectedPaths.contains(file.$1),
                                onSelectionChanged: () => setSheetState(() {
                                  if (selectedPaths.contains(file.$1)) {
                                    selectedPaths.remove(file.$1);
                                  } else {
                                    selectedPaths.add(file.$1);
                                  }
                                }),
                              );
                            },
                          ),
                  ),
                  if (selectedPaths.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.fromLTRB(spaceMD, spaceXS, spaceMD, spaceSM),
                      child: Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [colours.tertiaryInfo, colours.primaryPositive]),
                          borderRadius: BorderRadius.all(cornerRadiusSM),
                          boxShadow: [BoxShadow(color: colours.tertiaryInfo.withValues(alpha: 0.16), blurRadius: 16, offset: Offset(0, 4))],
                        ),
                        child: TextButton.icon(
                          onPressed: () async {
                            final selected = selectedPaths.toList()..sort();
                            final approved = await _showAiPrivacyPreview(selected);
                            if (!approved || !mounted) return;
                            Navigator.of(sheetContext).pop();
                            _inputController.text = 'Review the uncommitted changes in these selected files. Explain the important changes, flag risks, and suggest improvements:\n- ${selected.join('\n- ')}';
                            _sendMessage(contextPaths: selected);
                          },
                          style: ButtonStyle(
                            backgroundColor: WidgetStatePropertyAll(Colors.transparent),
                            shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                            padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceSM)),
                          ),
                          icon: FaIcon(FontAwesomeIcons.wandMagicSparkles, color: colours.primaryDark, size: textSM),
                          label: Text('Review ${selectedPaths.length} selected files',
                            style: TextStyle(color: colours.primaryDark, fontSize: textSM, fontWeight: FontWeight.w900)),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _repositoryContextEmptyState(String query) {
    final hasRepository = !_repoName.startsWith('No repository');
    return Center(
      child: Padding(
        padding: EdgeInsets.all(spaceLG),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 60, height: 60,
            decoration: BoxDecoration(gradient: LinearGradient(colors: [
              colours.primaryPositive.withValues(alpha: 0.18), colours.tertiaryInfo.withValues(alpha: 0.08),
            ]), shape: BoxShape.circle, border: Border.all(color: colours.primaryPositive.withValues(alpha: 0.18))),
            child: Center(child: FaIcon(query.isNotEmpty ? FontAwesomeIcons.magnifyingGlass : FontAwesomeIcons.circleCheck,
              color: colours.primaryPositive, size: textLG))),
          SizedBox(height: spaceSM),
          Text(query.isNotEmpty ? 'No matching paths' : (hasRepository ? 'Working tree is clean' : 'Select a repository'),
            style: TextStyle(color: colours.primaryLight, fontSize: textMD, fontWeight: FontWeight.w800)),
          SizedBox(height: spaceXXS),
          Text(query.isNotEmpty ? 'Try a different filename or folder.' : (hasRepository
              ? 'No uncommitted file changes to show.'
              : 'Choose a local repository to inspect its current context.'),
            textAlign: TextAlign.center, style: TextStyle(color: colours.secondaryLight, fontSize: textXS, height: 1.4)),
        ]),
      ),
    );
  }

  Future<bool> _showAiPrivacyPreview(List<String> paths) async {
    final diffFutures = <String, Future<GitManagerRs.WorkdirFileDiff?>>{
      for (final path in paths) path: GitManager.getWorkdirFileDiff(path),
    };
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colours.secondaryDark,
        title: Row(children: [
          FaIcon(FontAwesomeIcons.shieldHalved, color: colours.tertiaryInfo, size: textSM),
          SizedBox(width: spaceSM),
          Expanded(child: Text('Review AI context', style: TextStyle(color: colours.primaryLight, fontSize: textMD, fontWeight: FontWeight.w800))),
        ]),
        content: SizedBox(
          width: 560,
          height: MediaQuery.sizeOf(dialogContext).height * 0.55,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'Only the selected paths below can be newly read by AI tools for this request. The review starts with their current uncommitted diffs; the model may request more content from these files only. Secret-like values are redacted in file-tool output. Your existing chat history is also sent and may contain earlier context; start a new conversation first if you need an isolated review.',
              style: TextStyle(color: colours.secondaryLight, fontSize: textXS, height: 1.45),
            ),
            SizedBox(height: spaceSM),
            Text('${paths.length} selected ${paths.length == 1 ? 'file' : 'files'}',
              style: TextStyle(color: colours.tertiaryInfo, fontSize: textXXS, fontWeight: FontWeight.w900)),
            SizedBox(height: spaceXS),
            Expanded(
              child: ListView.separated(
                itemCount: paths.length,
                separatorBuilder: (context, index) => Divider(height: 1, color: colours.tertiaryDark),
                itemBuilder: (context, index) {
                  final path = paths[index];
                  return ExpansionTile(
                    initiallyExpanded: true,
                    tilePadding: EdgeInsets.zero,
                    iconColor: colours.tertiaryInfo,
                    collapsedIconColor: colours.secondaryLight,
                    title: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: _mono.merge(TextStyle(color: colours.primaryLight, fontSize: textXXS, fontWeight: FontWeight.w700))),
                    children: [
                      FutureBuilder<GitManagerRs.WorkdirFileDiff?>(
                        future: diffFutures[path],
                        builder: (context, snapshot) {
                          if (snapshot.connectionState != ConnectionState.done) {
                            return Padding(padding: EdgeInsets.all(spaceSM),
                              child: LinearProgressIndicator(color: colours.tertiaryInfo, backgroundColor: colours.tertiaryDark));
                          }
                          final diff = snapshot.data;
                          final preview = diff == null || diff.isBinary ? '' : _formatAiPrivacyDiff(diff);
                          return Container(
                            width: double.infinity,
                            constraints: BoxConstraints(maxHeight: 190),
                            margin: EdgeInsets.only(bottom: spaceSM),
                            padding: EdgeInsets.all(spaceSM),
                            decoration: BoxDecoration(color: colours.primaryDark, borderRadius: BorderRadius.all(cornerRadiusSM)),
                            child: SingleChildScrollView(
                              child: SelectableText(
                                snapshot.hasError ? 'Diff preview unavailable.'
                                    : diff == null ? 'No uncommitted diff is available for this file.'
                                    : diff.isBinary ? 'Binary file — no text diff can be previewed.'
                                    : preview.isEmpty ? 'No text changes.' : preview,
                                style: _mono.merge(TextStyle(color: colours.secondaryLight, fontSize: textXXS, height: 1.4)),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text('Cancel')),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: FaIcon(FontAwesomeIcons.wandMagicSparkles, size: textXS),
            label: Text('Continue to AI review'),
          ),
        ],
      ),
    );
    return approved == true;
  }

  String _formatAiPrivacyDiff(GitManagerRs.WorkdirFileDiff diff) {
    final full = diff.lines.map((line) => '${line.origin} ${redactAiSecrets(line.content)}').join();
    if (full.length <= 4000) return full;
    return '${full.substring(0, 4000)}\\n… [truncated; tool output is capped at 4,000 characters]';
  }

  Future<void> _showFileDiff(String path) async {
    final diffFuture = GitManager.getWorkdirFileDiff(path);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.84,
        minChildSize: 0.5,
        maxChildSize: 0.96,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [colours.secondaryDark, colours.primaryDark]),
            borderRadius: BorderRadius.vertical(top: Radius.circular(cornerRadiusLG.x)),
            border: Border.all(color: colours.tertiaryInfo.withValues(alpha: 0.2)),
          ),
          child: Column(children: [
            SizedBox(height: spaceSM),
            Container(width: 42, height: 4, decoration: BoxDecoration(color: colours.tertiaryLight.withValues(alpha: 0.55),
              borderRadius: BorderRadius.all(cornerRadiusMax))),
            Padding(
              padding: EdgeInsets.fromLTRB(spaceMD, spaceSM, spaceSM, spaceSM),
              child: Row(children: [
                Container(width: 38, height: 38,
                  decoration: BoxDecoration(gradient: LinearGradient(colors: [colours.tertiaryInfo.withValues(alpha: 0.2), colours.primaryPositive.withValues(alpha: 0.08)]),
                    borderRadius: BorderRadius.all(cornerRadiusSM)),
                  child: Center(child: FaIcon(FontAwesomeIcons.code, color: colours.tertiaryInfo, size: textSM))),
                SizedBox(width: spaceSM),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(path, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: _mono.merge(TextStyle(color: colours.primaryLight, fontSize: textXS, fontWeight: FontWeight.w700))),
                  SizedBox(height: 2),
                  Text('UNCOMMITTED DIFF', style: TextStyle(color: colours.tertiaryInfo, fontSize: textXXS,
                    fontWeight: FontWeight.w900, letterSpacing: 1.0)),
                ])),
                IconButton(tooltip: 'Close', onPressed: () => Navigator.of(sheetContext).pop(),
                  icon: FaIcon(FontAwesomeIcons.xmark, color: colours.secondaryLight, size: textSM)),
              ]),
            ),
            Expanded(
              child: FutureBuilder(
                future: diffFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: colours.tertiaryInfo)),
                      SizedBox(height: spaceSM),
                      Text('Building diff…', style: TextStyle(color: colours.secondaryLight, fontSize: textXS)),
                    ]));
                  }
                  final diff = snapshot.data;
                  if (snapshot.hasError || diff == null) {
                    return _diffNotice(FontAwesomeIcons.circleExclamation, 'Diff unavailable', 'Git could not create a working-tree diff for this path.');
                  }
                  if (diff.isBinary) {
                    return _diffNotice(FontAwesomeIcons.file, 'Binary file', 'This file cannot be displayed as a text diff.');
                  }
                  if (diff.lines.isEmpty) {
                    return _diffNotice(FontAwesomeIcons.circleCheck, 'No text changes', 'The file may be staged, unchanged, or only its metadata changed.');
                  }
                  return Column(children: [
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: spaceMD, vertical: spaceXS),
                      child: Row(children: [
                        _diffStat('+${diff.insertions}', colours.primaryPositive),
                        SizedBox(width: spaceXS),
                        _diffStat('−${diff.deletions}', colours.primaryNegative),
                        Spacer(),
                        Text('${diff.lines.length} lines', style: TextStyle(color: colours.secondaryLight, fontSize: textXXS)),
                      ]),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: scrollController,
                        padding: EdgeInsets.only(bottom: spaceSM),
                        itemCount: diff.lines.length,
                        itemBuilder: (context, index) {
                          final line = diff.lines[index];
                          final added = line.origin == '+';
                          final removed = line.origin == '-';
                          final tint = added ? colours.primaryPositive : removed ? colours.primaryNegative : colours.secondaryLight;
                          final background = added ? colours.primaryPositive.withValues(alpha: 0.075)
                              : removed ? colours.primaryNegative.withValues(alpha: 0.075) : Colors.transparent;
                          return Container(
                            color: background,
                            padding: EdgeInsets.symmetric(vertical: spaceXXXS),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(children: [
                                _diffLineNumber(line.oldLineno),
                                _diffLineNumber(line.newLineno),
                                SizedBox(width: spaceXS),
                                Text('${line.origin} ${line.content}', softWrap: false,
                                  style: _mono.merge(TextStyle(color: tint, fontSize: textXS, height: 1.45))),
                              ]),
                            ),
                          );
                        },
                      ),
                    ),
                  ]);
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(spaceMD, spaceXS, spaceMD, spaceSM),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [colours.tertiaryInfo, colours.primaryPositive]),
                  borderRadius: BorderRadius.all(cornerRadiusSM),
                  boxShadow: [BoxShadow(color: colours.tertiaryInfo.withValues(alpha: 0.18), blurRadius: 18, offset: Offset(0, 5))],
                ),
                child: TextButton.icon(
                  onPressed: () async {
                    final approved = await _showAiPrivacyPreview([path]);
                    if (!approved || !mounted) return;
                    Navigator.of(sheetContext).pop();
                    _inputController.text = 'Review the uncommitted diff for "$path". Explain the intent, point out potential bugs, and suggest improvements.';
                    _sendMessage(contextPaths: [path]);
                  },
                  style: ButtonStyle(
                    backgroundColor: WidgetStatePropertyAll(Colors.transparent),
                    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceSM)),
                  ),
                  icon: FaIcon(FontAwesomeIcons.wandMagicSparkles, color: colours.primaryDark, size: textSM),
                  label: Text('Ask AI to review this diff', style: TextStyle(color: colours.primaryDark, fontSize: textSM, fontWeight: FontWeight.w900)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _diffLineNumber(int number) {
    return SizedBox(
      width: 42,
      child: Text(number == 0 ? '' : '$number', textAlign: TextAlign.right,
        style: _mono.merge(TextStyle(color: colours.tertiaryLight, fontSize: textXXS, height: 1.45))),
    );
  }

  Widget _diffStat(String value, Color tint) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: spaceXS, vertical: spaceXXS),
      decoration: BoxDecoration(color: tint.withValues(alpha: 0.1), borderRadius: BorderRadius.all(cornerRadiusMax),
        border: Border.all(color: tint.withValues(alpha: 0.17))),
      child: Text(value, style: TextStyle(color: tint, fontSize: textXS, fontWeight: FontWeight.w900)),
    );
  }

  Widget _diffNotice(FaIconData icon, String title, String detail) {
    return Center(child: Padding(padding: EdgeInsets.all(spaceLG), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 54, height: 54, decoration: BoxDecoration(color: colours.tertiaryInfo.withValues(alpha: 0.1), shape: BoxShape.circle),
        child: Center(child: FaIcon(icon, color: colours.tertiaryInfo, size: textLG))),
      SizedBox(height: spaceSM),
      Text(title, style: TextStyle(color: colours.primaryLight, fontSize: textMD, fontWeight: FontWeight.w800)),
      SizedBox(height: spaceXXS),
      Text(detail, textAlign: TextAlign.center, style: TextStyle(color: colours.secondaryLight, fontSize: textXS, height: 1.4)),
    ])));
  }

  Widget _changedFileTile((String, int) file, {required bool selected, required VoidCallback onSelectionChanged}) {
    final path = file.$1;
    final status = file.$2;
    final tint = status == 2 ? colours.primaryNegative : status == 3 ? colours.primaryPositive : colours.tertiaryInfo;
    final label = switch (status) { 2 => 'DELETED', 3 => 'ADDED', _ => 'MODIFIED' };
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.all(cornerRadiusSM),
      child: InkWell(
        borderRadius: BorderRadius.all(cornerRadiusSM),
        onTap: () => _showFileDiff(path),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: spaceSM, vertical: spaceSM),
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [colours.tertiaryDark.withValues(alpha: 0.58), colours.secondaryDark.withValues(alpha: 0.72)]),
            borderRadius: BorderRadius.all(cornerRadiusSM),
            border: Border.all(color: tint.withValues(alpha: 0.16)),
          ),
          child: Row(children: [
            Container(width: 36, height: 36,
              decoration: BoxDecoration(color: tint.withValues(alpha: 0.11), borderRadius: BorderRadius.all(cornerRadiusXS)),
              child: Center(child: FaIcon(status == 2 ? FontAwesomeIcons.trashCan : FontAwesomeIcons.fileLines, color: tint, size: textSM))),
            SizedBox(width: spaceSM),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(path, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: _mono.merge(TextStyle(color: colours.primaryLight, fontSize: textXS, height: 1.3))),
              SizedBox(height: spaceXXXS),
              Text('Tap to inspect diff', style: TextStyle(color: colours.secondaryLight, fontSize: textXXS)),
            ])),
            Checkbox.adaptive(
              value: selected,
              onChanged: (_) => onSelectionChanged(),
              activeColor: colours.tertiaryInfo,
              checkColor: colours.primaryDark,
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              tooltip: 'Copy file path',
              visualDensity: VisualDensity.compact,
              onPressed: () => _copyText(path, 'Path copied'),
              icon: FaIcon(FontAwesomeIcons.copy, color: colours.secondaryLight, size: textXS),
            ),
            Container(
              padding: EdgeInsets.symmetric(horizontal: spaceXS, vertical: spaceXXS),
              decoration: BoxDecoration(color: tint.withValues(alpha: 0.09), borderRadius: BorderRadius.all(cornerRadiusMax),
                border: Border.all(color: tint.withValues(alpha: 0.18))),
              child: Text(label, style: TextStyle(color: tint, fontSize: textXXS, fontWeight: FontWeight.w900, letterSpacing: 0.3)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _emptyState() {
    return ListView(
      reverse: true,
      padding: EdgeInsets.fromLTRB(spaceMD, spaceXL + spaceLG + spaceMD, spaceMD, spaceMD),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(spaceMD),
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                  colors: [colours.secondaryDark, colours.showcaseBg, colours.primaryDark]),
                borderRadius: BorderRadius.all(cornerRadiusMD),
                border: Border.all(color: colours.tertiaryInfo.withValues(alpha: 0.26)),
                boxShadow: [BoxShadow(color: colours.tertiaryInfo.withValues(alpha: 0.08), blurRadius: 28, spreadRadius: 1)],
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(width: 7, height: 7, decoration: BoxDecoration(color: colours.primaryPositive, shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: colours.primaryPositive.withValues(alpha: 0.65), blurRadius: 9)])),
                  SizedBox(width: spaceXS),
                  Text('REPOSITORY COPILOT', style: TextStyle(color: colours.tertiaryInfo, fontSize: textXXS,
                    fontWeight: FontWeight.w900, letterSpacing: 1.6)),
                  Spacer(),
                  FaIcon(FontAwesomeIcons.sparkles, color: colours.primaryPositive.withValues(alpha: 0.85), size: textSM),
                ]),
                SizedBox(height: spaceSM),
                Row(children: [
                  _PulsingBrandMark(size: 68),
                  SizedBox(width: spaceSM),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Your repo,\nin context.', style: TextStyle(color: colours.primaryLight, fontSize: 24,
                      height: 1.04, letterSpacing: -0.7, fontWeight: FontWeight.w900)),
                    SizedBox(height: spaceXS),
                    Text('A thoughtful AI partner for every branch, diff and idea.',
                      style: TextStyle(color: colours.secondaryLight, fontSize: textXS, height: 1.4)),
                  ])),
                ]),
                SizedBox(height: spaceMD),
                Wrap(spacing: spaceXS, runSpacing: spaceXS, children: [
                  _contextPill(FontAwesomeIcons.folderOpen, _repoName, colours.tertiaryInfo),
                  _contextPill(FontAwesomeIcons.codeBranch, _branchName ?? 'Git workspace', colours.primaryPositive),
                  _contextPill(FontAwesomeIcons.fileLines,
                    _changedFileCount == 0 ? 'Clean worktree' : '$_changedFileCount changed',
                    _changedFileCount == 0 ? colours.primaryPositive : colours.primaryWarning),
                ]),
                SizedBox(height: spaceSM),
                Container(height: 1, decoration: BoxDecoration(gradient: LinearGradient(colors: [
                  colours.tertiaryInfo.withValues(alpha: 0.35), colours.tertiaryInfo.withValues(alpha: 0.02),
                ]))),
                SizedBox(height: spaceSM),
                Row(children: [
                  FaIcon(FontAwesomeIcons.lock, color: colours.secondaryLight, size: textXXS),
                  SizedBox(width: spaceXXS),
                  Expanded(child: Text('Private by design · Your key stays on this device',
                    style: TextStyle(color: colours.secondaryLight, fontSize: textXXS, fontWeight: FontWeight.w600))),
                  FaIcon(FontAwesomeIcons.shieldHalved, color: colours.primaryPositive, size: textXXS),
                ]),
              ]),
            ),
            SizedBox(height: spaceLG),
            Row(children: [
              Container(width: 36, height: 36,
                decoration: BoxDecoration(color: colours.tertiaryInfo.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.all(cornerRadiusSM), border: Border.all(color: colours.tertiaryInfo.withValues(alpha: 0.18))),
                child: Center(child: FaIcon(FontAwesomeIcons.bolt, color: colours.tertiaryInfo, size: textSM))),
              SizedBox(width: spaceSM),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Pick a starting point', style: TextStyle(color: colours.primaryLight, fontSize: textMD, fontWeight: FontWeight.w800)),
                SizedBox(height: 2),
                Text('FOUR SHORTCUTS · ONE SHARED CONTEXT', style: TextStyle(color: colours.tertiaryLight,
                  fontSize: textXXS, fontWeight: FontWeight.w800, letterSpacing: 0.7)),
              ])),
            ]),
            SizedBox(height: spaceSM),
            LayoutBuilder(builder: (context, constraints) {
              final width = (constraints.maxWidth - spaceXS) / 2;
              return Wrap(spacing: spaceXS, runSpacing: spaceXS, children: [
                _quickAction(FontAwesomeIcons.codeBranch, 'Review my changes', 'Summarize the working tree', width: width, accent: colours.primaryPositive),
                _quickAction(FontAwesomeIcons.folderOpen, 'Explain this project', 'Map the main folders and entry points', width: width, accent: colours.tertiaryInfo),
                _quickAction(FontAwesomeIcons.magnifyingGlass, 'Find risks and TODOs', 'Search for unfinished or risky code', width: width, accent: colours.primaryWarning),
                _quickAction(FontAwesomeIcons.codeCommit, 'Suggest a commit', 'Draft a message from the current diff', width: width, accent: colours.showcaseBtnPrimary),
              ]);
            }),
            SizedBox(height: spaceMD),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              FaIcon(FontAwesomeIcons.shieldHalved, color: colours.primaryPositive, size: textXS),
              SizedBox(width: spaceXXS),
              Flexible(child: Text('AI can help you move faster. Review generated suggestions before applying them.',
                textAlign: TextAlign.center, style: TextStyle(color: colours.secondaryLight, fontSize: textXXS, height: 1.35))),
            ]),
            SizedBox(height: spaceLG),
          ],
        ),
      ],
    );
  }

  Widget _contextPill(FaIconData icon, String label, Color tint) {
    return Container(
      constraints: BoxConstraints(maxWidth: 210),
      padding: EdgeInsets.symmetric(horizontal: spaceXS, vertical: spaceXXS),
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [tint.withValues(alpha: 0.13), tint.withValues(alpha: 0.045)]),
        borderRadius: BorderRadius.all(cornerRadiusMax),
        border: Border.all(color: tint.withValues(alpha: 0.24)),
        boxShadow: [BoxShadow(color: tint.withValues(alpha: 0.045), blurRadius: 10)],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        FaIcon(icon, color: tint, size: textXXS),
        SizedBox(width: spaceXXS),
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(color: colours.primaryLight, fontSize: textXXS, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  Widget _quickAction(FaIconData icon, String title, String subtitle, {required double width, required Color accent}) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.94, end: 1),
      duration: animMedium,
      curve: Curves.easeOutBack,
      builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
      child: SizedBox(
        width: width,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.all(cornerRadiusSM),
          child: InkWell(
            borderRadius: BorderRadius.all(cornerRadiusSM),
            splashColor: accent.withValues(alpha: 0.14),
            highlightColor: accent.withValues(alpha: 0.06),
            onTap: () {
              HapticFeedback.selectionClick();
              _inputController.text = title;
              _sendMessage();
            },
            child: Container(
              constraints: BoxConstraints(minHeight: 126),
              child: Ink(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [accent.withValues(alpha: 0.14), colours.secondaryDark.withValues(alpha: 0.94), colours.secondaryDark],
                  ),
                  borderRadius: BorderRadius.all(cornerRadiusSM),
                  border: Border.all(color: accent.withValues(alpha: 0.23)),
                  boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.06), blurRadius: 18, offset: Offset(0, 7))],
                ),
                child: Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 16,
                      right: 16,
                      child: Container(
                        height: 1,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [Colors.transparent, accent.withValues(alpha: 0.65), Colors.transparent]),
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.all(spaceSM),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [accent.withValues(alpha: 0.32), accent.withValues(alpha: 0.09)],
                                  ),
                                  borderRadius: BorderRadius.all(cornerRadiusSM),
                                  border: Border.all(color: accent.withValues(alpha: 0.22)),
                                ),
                                child: Center(child: FaIcon(icon, color: accent, size: textSM)),
                              ),
                              Spacer(),
                              Container(
                                width: 27,
                                height: 27,
                                decoration: BoxDecoration(
                                  color: colours.primaryDark.withValues(alpha: 0.36),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: accent.withValues(alpha: 0.17)),
                                ),
                                child: Center(child: FaIcon(FontAwesomeIcons.arrowUpRight, color: colours.secondaryLight, size: textXXS)),
                              ),
                            ],
                          ),
                          SizedBox(height: spaceSM),
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colours.primaryLight, fontSize: textXS, fontWeight: FontWeight.w800, height: 1.15),
                          ),
                          SizedBox(height: spaceXXS),
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colours.secondaryLight, fontSize: textXXS, height: 1.3),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMessage(ChatMessage msg) {
    final Widget content;
    switch (msg.role) {
      case ChatRole.user:
        content = Align(alignment: Alignment.centerRight, child: _prompt(msg.textContent));
        break;
      case ChatRole.assistant:
        final widgets = <Widget>[];
        for (final block in msg.content) {
          if (block is TextBlock && block.text.isNotEmpty) {
            widgets.add(_responseMarkdown(block.text));
            widgets.add(SizedBox(height: spaceXS));
          } else if (block is ToolUseBlock) {
            widgets.add(_toolUseWidget(block));
            widgets.add(SizedBox(height: spaceXS));
          }
        }
        if (widgets.isNotEmpty && widgets.last is SizedBox) widgets.removeLast();
        widgets.insertAll(0, [
          Row(children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(color: colours.primaryPositive, shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: colours.primaryPositive.withValues(alpha: 0.55), blurRadius: 6)])),
            SizedBox(width: spaceXXS),
            Text('REPOSYNC AI', style: TextStyle(color: colours.tertiaryInfo, fontSize: textXXS,
              fontWeight: FontWeight.w900, letterSpacing: 1.1)),
            Spacer(),
            if (msg.textContent.trim().isNotEmpty)
              Tooltip(message: 'Copy response', child: InkWell(
                borderRadius: BorderRadius.all(cornerRadiusXS),
                onTap: () => _copyText(msg.textContent, 'Response copied'),
                child: Padding(padding: EdgeInsets.all(spaceXXS),
                  child: FaIcon(FontAwesomeIcons.copy, color: colours.secondaryLight, size: textXS)),
              )),
          ]),
          SizedBox(height: spaceXS),
        ]);
        content = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: msg.textContent.trim().isEmpty ? null : () async {
            await Clipboard.setData(ClipboardData(text: msg.textContent));
            HapticFeedback.selectionClick();
            Fluttertoast.showToast(msg: 'Response copied', toastLength: Toast.LENGTH_SHORT);
          },
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 30, height: 30, margin: EdgeInsets.only(top: spaceXXS),
              decoration: BoxDecoration(gradient: LinearGradient(colors: [colours.tertiaryInfo, colours.primaryPositive]), shape: BoxShape.circle),
              child: Icon(FontAwesomeIcons.wandMagicSparkles, size: textXS, color: colours.primaryDark)),
            SizedBox(width: spaceXS),
            Expanded(child: Container(
              padding: EdgeInsets.all(spaceSM),
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                  colors: [colours.secondaryDark.withValues(alpha: 0.96), colours.secondaryDark.withValues(alpha: 0.84)]),
                borderRadius: BorderRadius.only(topLeft: Radius.circular(cornerRadiusSM.x), topRight: Radius.circular(cornerRadiusSM.x),
                  bottomRight: Radius.circular(cornerRadiusSM.x), bottomLeft: Radius.circular(spaceXXS)),
                border: Border.all(color: colours.tertiaryInfo.withValues(alpha: 0.16)),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 16, offset: Offset(0, 5))],
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: widgets),
            )),
          ]),
        );
      case ChatRole.tool:
        return const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.only(bottom: spaceSM),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1),
        duration: Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) => Opacity(opacity: value,
          child: Transform.translate(offset: Offset(0, (1 - value) * 8), child: child)),
        child: content,
      ),
    );
  }

  Widget _prompt(String text) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.84),
      child: GestureDetector(
        onLongPress: () async {
          await Clipboard.setData(ClipboardData(text: text));
          HapticFeedback.selectionClick();
          Fluttertoast.showToast(msg: 'Copied to clipboard', toastLength: Toast.LENGTH_SHORT);
        },
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: spaceMD, vertical: spaceSM),
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [colours.tertiaryInfo.withValues(alpha: 0.22), colours.secondaryDark]),
            borderRadius: BorderRadius.only(topLeft: Radius.circular(cornerRadiusSM.x), topRight: Radius.circular(cornerRadiusSM.x),
              bottomLeft: Radius.circular(cornerRadiusSM.x), bottomRight: Radius.circular(spaceXXS)),
            border: Border.all(color: colours.tertiaryInfo.withValues(alpha: 0.28)),
          ),
          child: _LinkifiedText(text,
            style: TextStyle(color: colours.primaryLight, fontSize: textSM, height: 1.4, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _responseMarkdown(String text) {
    return MarkdownBlock(data: text, config: buildMarkdownConfig(), generator: buildMarkdownGenerator());
  }

  Widget _responseStreaming(String text) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(width: 30, height: 30, margin: EdgeInsets.only(top: spaceXXS),
        decoration: BoxDecoration(gradient: LinearGradient(colors: [colours.tertiaryInfo, colours.primaryPositive]), shape: BoxShape.circle),
        child: Icon(FontAwesomeIcons.wandMagicSparkles, size: textXS, color: colours.primaryDark)),
      SizedBox(width: spaceXS),
      Expanded(child: Container(padding: EdgeInsets.all(spaceSM),
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [colours.secondaryDark.withValues(alpha: 0.98), colours.secondaryDark.withValues(alpha: 0.82)]),
          borderRadius: BorderRadius.all(cornerRadiusSM),
          border: Border.all(color: colours.tertiaryInfo.withValues(alpha: 0.23)),
          boxShadow: [BoxShadow(color: colours.tertiaryInfo.withValues(alpha: 0.05), blurRadius: 18, offset: Offset(0, 5))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 6, height: 6, decoration: BoxDecoration(color: colours.primaryPositive, shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: colours.primaryPositive.withValues(alpha: 0.6), blurRadius: 6)])),
            SizedBox(width: spaceXXS),
            Text('WORKING ON IT', style: TextStyle(color: colours.tertiaryInfo, fontSize: textXXS,
              fontWeight: FontWeight.w900, letterSpacing: 1.0)),
            Spacer(),
            _typingIndicator(),
          ]),
          SizedBox(height: spaceSM),
          Text(text, style: TextStyle(color: colours.primaryLight, fontSize: textSM, height: 1.45)),
        ]),
      )),
    ]);
  }

  Widget _typingIndicator() {
    return _AnimatedDots();
  }

  Widget _toolUseWidget(ToolUseBlock block) {
    final statusIcon = switch (block.status) {
      ToolCallStatus.pending => FontAwesomeIcons.clock,
      ToolCallStatus.approved => FontAwesomeIcons.check,
      ToolCallStatus.rejected => FontAwesomeIcons.xmark,
      ToolCallStatus.running => FontAwesomeIcons.spinner,
      ToolCallStatus.completed => FontAwesomeIcons.check,
      ToolCallStatus.failed => FontAwesomeIcons.triangleExclamation,
    };
    final statusColor = switch (block.status) {
      ToolCallStatus.pending => colours.secondaryLight,
      ToolCallStatus.approved || ToolCallStatus.completed => colours.primaryPositive,
      ToolCallStatus.rejected => colours.primaryNegative,
      ToolCallStatus.running => colours.tertiaryInfo,
      ToolCallStatus.failed => colours.primaryNegative,
    };

    final inputSummary = _summarizeToolInput(block.toolName, block.input);

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: colours.tertiaryDark),
        borderRadius: BorderRadius.all(cornerRadiusSM),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(horizontal: spaceSM, vertical: spaceXXS),
            decoration: BoxDecoration(
              color: colours.tertiaryDark,
              borderRadius: BorderRadius.vertical(top: Radius.circular(cornerRadiusSM.x)),
            ),
            child: Row(
              children: [
                FaIcon(statusIcon, color: statusColor, size: textXS),
                SizedBox(width: spaceXS),
                Expanded(
                  child: Text(
                    "${block.toolName}  $inputSummary",
                    style: _mono.merge(TextStyle(color: colours.secondaryLight, fontSize: textXS)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          if (block.output != null || block.error != null) Padding(padding: EdgeInsets.all(spaceSM), child: _toolResultContent(block)),
        ],
      ),
    );
  }

  Widget _toolResultContent(ToolUseBlock block) {
    if (block.error != null) {
      return Text(
        block.error!,
        style: _mono.merge(TextStyle(color: colours.primaryNegative, fontSize: textXS)),
      );
    }

    final output = block.output ?? '';
    try {
      final json = jsonDecode(output);
      final result = json['result'];
      final error = json['error'];
      if (error != null) {
        return Text(
          error.toString(),
          style: _mono.merge(TextStyle(color: colours.primaryNegative, fontSize: textXS)),
        );
      }
      if (result is String) {
        return Text(
          result,
          style: _mono.merge(TextStyle(color: colours.secondaryLight, fontSize: textXS)),
          maxLines: 20,
          overflow: TextOverflow.ellipsis,
        );
      }
      if (result is Map || result is List) {
        final formatted = const JsonEncoder.withIndent('  ').convert(result);
        return Text(
          formatted,
          style: _mono.merge(TextStyle(color: colours.secondaryLight, fontSize: textXS)),
          maxLines: 20,
          overflow: TextOverflow.ellipsis,
        );
      }
      return Text(
        result.toString(),
        style: _mono.merge(TextStyle(color: colours.secondaryLight, fontSize: textXS)),
      );
    } catch (_) {
      return Text(
        output,
        style: _mono.merge(TextStyle(color: colours.secondaryLight, fontSize: textXS)),
        maxLines: 20,
        overflow: TextOverflow.ellipsis,
      );
    }
  }

  String _summarizeToolInput(String toolName, Map<String, dynamic> input) {
    if (input['paths'] is List) return (input['paths'] as List).join(', ');
    if (input['path'] is String) return input['path'] as String;
    if (input['file_path'] is String) return input['file_path'] as String;
    if (input['name'] is String) return input['name'] as String;
    if (input['commit_sha'] is String) return input['commit_sha'] as String;
    if (input['message'] is String) {
      final msg = input['message'] as String;
      return msg.length > 50 ? '${msg.substring(0, 50)}...' : msg;
    }
    if (input['pattern'] is String) return input['pattern'] as String;
    return '';
  }

  Widget _confirmationChip(AiTool tool) {
    final isDanger = tool.confirmation == ToolConfirmation.danger;
    final isConfirm = tool.confirmation == ToolConfirmation.confirm || isDanger;
    final isEdit = editToolNames.contains(tool.name);
    final borderColor = isConfirm ? colours.primaryNegative : colours.primaryWarning;

    if (isDanger) return _dangerConfirmationChip(tool);

    return Container(
      margin: EdgeInsets.only(bottom: spaceSM),
      padding: EdgeInsets.all(spaceSM),
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.all(cornerRadiusSM),
        color: borderColor.withValues(alpha: 0.08),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Allow ${tool.name}?",
            style: _mono.merge(TextStyle(color: colours.primaryLight, fontSize: textSM, fontWeight: FontWeight.bold)),
          ),
          SizedBox(height: spaceXS),
          Text(
            tool.description,
            style: TextStyle(color: colours.secondaryLight, fontSize: textXS),
          ),
          SizedBox(height: spaceSM),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => _confirmationCompleter?.complete(false),
                  style: ButtonStyle(
                    backgroundColor: WidgetStatePropertyAll(colours.tertiaryDark),
                    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceXS)),
                  ),
                  child: Text(
                    "Reject",
                    style: TextStyle(color: colours.primaryNegative, fontSize: textSM, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              SizedBox(width: spaceXS),
              Expanded(
                child: TextButton(
                  onPressed: () => _confirmationCompleter?.complete(true),
                  style: ButtonStyle(
                    backgroundColor: WidgetStatePropertyAll(
                      isConfirm ? colours.primaryNegative.withValues(alpha: 0.15) : colours.primaryWarning.withValues(alpha: 0.15),
                    ),
                    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceXS)),
                  ),
                  child: Text(
                    "Allow",
                    style: TextStyle(
                      color: isConfirm ? colours.primaryNegative : colours.primaryWarning,
                      fontSize: textSM,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: spaceXS),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () {
                aiChatService.allowToolsForSession(isEdit ? editToolNames : [tool.name]);
                _confirmationCompleter?.complete(true);
              },
              style: ButtonStyle(
                backgroundColor: WidgetStatePropertyAll(colours.tertiaryDark),
                shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceXS)),
              ),
              child: Text(
                isEdit ? t.aiAllowAllEdits : t.aiAlwaysAllowSession,
                style: TextStyle(color: colours.secondaryLight, fontSize: textSM, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dangerConfirmationChip(AiTool tool) {
    final confirmController = TextEditingController();
    return StatefulBuilder(
      builder: (context, setChipState) {
        final typed = confirmController.text.trim().toUpperCase() == 'CONFIRM';
        return Container(
          margin: EdgeInsets.only(bottom: spaceSM),
          padding: EdgeInsets.all(spaceSM),
          decoration: BoxDecoration(
            border: Border.all(color: colours.primaryNegative, width: 2),
            borderRadius: BorderRadius.all(cornerRadiusSM),
            color: colours.primaryNegative.withValues(alpha: 0.12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  FaIcon(FontAwesomeIcons.triangleExclamation, color: colours.primaryNegative, size: textSM),
                  SizedBox(width: spaceXS),
                  Expanded(
                    child: Text(
                      "Destructive: ${tool.name}",
                      style: _mono.merge(TextStyle(color: colours.primaryNegative, fontSize: textSM, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
              SizedBox(height: spaceXS),
              Text(
                tool.description,
                style: TextStyle(color: colours.primaryLight, fontSize: textXS),
              ),
              SizedBox(height: spaceSM),
              Text(
                "Type CONFIRM to proceed:",
                style: TextStyle(color: colours.secondaryLight, fontSize: textXS),
              ),
              SizedBox(height: spaceXXS),
              TextField(
                controller: confirmController,
                onChanged: (_) => setChipState(() {}),
                style: _mono.merge(TextStyle(color: colours.primaryLight, fontSize: textSM)),
                decoration: InputDecoration(
                  hintText: "CONFIRM",
                  hintStyle: _mono.merge(TextStyle(color: colours.tertiaryDark, fontSize: textSM)),
                  filled: true,
                  fillColor: colours.primaryDark,
                  border: OutlineInputBorder(borderRadius: BorderRadius.all(cornerRadiusSM), borderSide: BorderSide.none),
                  contentPadding: EdgeInsets.symmetric(horizontal: spaceSM, vertical: spaceXS),
                ),
              ),
              SizedBox(height: spaceSM),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () {
                        confirmController.dispose();
                        _confirmationCompleter?.complete(false);
                      },
                      style: ButtonStyle(
                        backgroundColor: WidgetStatePropertyAll(colours.tertiaryDark),
                        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceXS)),
                      ),
                      child: Text(
                        "Reject",
                        style: TextStyle(color: colours.primaryNegative, fontSize: textSM, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  SizedBox(width: spaceXS),
                  Expanded(
                    child: TextButton(
                      onPressed: typed
                          ? () {
                              confirmController.dispose();
                              _confirmationCompleter?.complete(true);
                            }
                          : null,
                      style: ButtonStyle(
                        backgroundColor: WidgetStatePropertyAll(typed ? colours.primaryNegative : colours.tertiaryDark),
                        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceXS)),
                      ),
                      child: Text(
                        "I understand, proceed",
                        style: TextStyle(color: typed ? colours.primaryDark : colours.secondaryLight, fontSize: textSM, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _showTokenDialog(BuildContext context) async {
    final isSelfHosted = _currentProvider == 'Self-hosted';
    String? selectedChatModel = _currentChatModel;
    String? selectedToolModel = _currentToolModel;
    String? selectedWandModel = _currentWandModel;
    List<String> availableModels = [];
    bool loadingModels = true;

    void Function(void Function())? _setDialogState;

    () async {
      final provider = aiProviderFromString(_currentProvider);
      if (provider != null) {
        final apiKey = await repoManager.getStringNullable(StorageKey.repoman_aiApiKey) ?? '';
        final endpoint = isSelfHosted ? await repoManager.getStringNullable(StorageKey.repoman_aiEndpoint) : null;
        final (models, _) = await fetchAvailableModels(provider: provider, apiKey: apiKey, endpoint: endpoint);
        availableModels = models;
      }
      loadingModels = false;
      _setDialogState?.call(() {});
    }();

    final signedOut = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          _setDialogState = setDialogState;

          Widget modelRow({required String label, required String? selectedValue, required void Function(String) onChanged}) {
            final displayed = selectedValue ?? '';
            return Row(
              children: [
                Text(
                  label,
                  style: TextStyle(color: colours.secondaryLight, fontSize: textXS),
                ),
                SizedBox(width: spaceSM),
                Expanded(
                  child: loadingModels
                      ? Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            SizedBox(
                              width: textSM,
                              height: textSM,
                              child: CircularProgressIndicator(strokeWidth: 1.5, color: colours.secondaryLight),
                            ),
                            SizedBox(width: spaceXS),
                            Text(
                              displayed,
                              style: _mono.merge(TextStyle(color: colours.primaryLight, fontSize: textXS)),
                            ),
                          ],
                        )
                      : availableModels.isNotEmpty
                      ? DropdownButton<String>(
                          value: availableModels.contains(selectedValue) ? selectedValue : null,
                          hint: Text(
                            displayed,
                            style: _mono.merge(TextStyle(color: colours.primaryLight, fontSize: textXS)),
                          ),
                          isExpanded: true,
                          dropdownColor: colours.secondaryDark,
                          underline: SizedBox.shrink(),
                          isDense: true,
                          alignment: AlignmentDirectional.centerEnd,
                          style: _mono.merge(TextStyle(color: colours.primaryLight, fontSize: textXS)),
                          items: availableModels
                              .map(
                                (m) => DropdownMenuItem(
                                  value: m,
                                  alignment: AlignmentDirectional.centerEnd,
                                  child: Text(m, overflow: TextOverflow.ellipsis),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            onChanged(v);
                          },
                        )
                      : Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            displayed,
                            style: _mono.merge(TextStyle(color: colours.primaryLight, fontSize: textXS, fontWeight: FontWeight.bold)),
                          ),
                        ),
                ),
              ],
            );
          }

          return Dialog(
            backgroundColor: colours.secondaryDark,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusMD)),
            child: Padding(
              padding: EdgeInsets.all(spaceMD),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      FaIcon(FontAwesomeIcons.microchip, color: colours.tertiaryInfo, size: textLG),
                      SizedBox(width: spaceXS),
                      Text(
                        "AI Settings",
                        style: TextStyle(color: colours.primaryLight, fontSize: textLG, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  SizedBox(height: spaceMD),

                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(spaceSM),
                    decoration: BoxDecoration(color: colours.tertiaryDark, borderRadius: BorderRadius.all(cornerRadiusSM)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              "Provider",
                              style: TextStyle(color: colours.secondaryLight, fontSize: textXS),
                            ),
                            Spacer(),
                            Text(
                              _currentProvider ?? '',
                              style: _mono.merge(TextStyle(color: colours.tertiaryInfo, fontSize: textXS, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                        SizedBox(height: spaceXS),
                        modelRow(
                          label: "Chat",
                          selectedValue: selectedChatModel,
                          onChanged: (v) async {
                            await repoManager.setStringNullable(StorageKey.repoman_aiChatModel, v);
                            setDialogState(() => selectedChatModel = v);
                            if (mounted) setState(() => _currentChatModel = v);
                          },
                        ),
                        SizedBox(height: spaceXS),
                        modelRow(
                          label: "Tool",
                          selectedValue: selectedToolModel,
                          onChanged: (v) async {
                            await repoManager.setStringNullable(StorageKey.repoman_aiToolModel, v);
                            setDialogState(() => selectedToolModel = v);
                            if (mounted) setState(() => _currentToolModel = v);
                          },
                        ),
                        SizedBox(height: spaceXS),
                        modelRow(
                          label: "Wand",
                          selectedValue: selectedWandModel,
                          onChanged: (v) async {
                            await repoManager.setStringNullable(StorageKey.repoman_aiWandModel, v);
                            setDialogState(() => selectedWandModel = v);
                            if (mounted) setState(() => _currentWandModel = v);
                          },
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: spaceMD),

                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () async {
                            aiChatService.stop(); // cancel active stream before wiping credentials
                            await repoManager.setStringNullable(StorageKey.repoman_aiProvider, null);
                            await repoManager.setStringNullable(StorageKey.repoman_aiApiKey, null);
                            await repoManager.setStringNullable(StorageKey.repoman_aiEndpoint, null);
                            await repoManager.setStringNullable(StorageKey.repoman_aiChatModel, null);
                            await repoManager.setStringNullable(StorageKey.repoman_aiToolModel, null);
                            await repoManager.setStringNullable(StorageKey.repoman_aiWandModel, null);
                            ref.read(aiKeyConfiguredProvider.notifier).state = false;
                            await aiChatService.clearConversation(clearHistory: true);
                            Navigator.pop(context, true);
                            _checkStoredApiKey();
                          },
                          style: ButtonStyle(
                            backgroundColor: WidgetStatePropertyAll(colours.tertiaryDark),
                            shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                            padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceSM)),
                          ),
                          child: Text(
                            "Sign Out",
                            style: TextStyle(color: colours.primaryNegative, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      SizedBox(width: spaceXS),
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          style: ButtonStyle(
                            backgroundColor: WidgetStatePropertyAll(colours.tertiaryInfo),
                            shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                            padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceSM)),
                          ),
                          child: Text(
                            "Done",
                            style: TextStyle(color: colours.primaryDark, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    _setDialogState = null;

    if (signedOut == true && mounted) {
      setState(() => _initialized = false);
    }
  }

  void _confirmStop(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: colours.secondaryDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusMD)),
        child: Padding(
          padding: EdgeInsets.all(spaceMD),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Stop generating?",
                style: TextStyle(color: colours.primaryLight, fontSize: textLG, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: spaceXS),
              Text(
                t.aiStopGeneratingMsg,
                style: TextStyle(color: colours.secondaryLight, fontSize: textSM),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: spaceMD),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: ButtonStyle(
                        backgroundColor: WidgetStatePropertyAll(colours.tertiaryDark),
                        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceSM)),
                      ),
                      child: Text(
                        "Continue",
                        style: TextStyle(color: colours.primaryLight, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  SizedBox(width: spaceXS),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ButtonStyle(
                        backgroundColor: WidgetStatePropertyAll(colours.primaryNegative),
                        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceSM)),
                      ),
                      child: Text(
                        "Stop",
                        style: TextStyle(color: colours.primaryDark, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed == true) aiChatService.stop();
  }

  Future<void> _confirmClearChat(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: colours.secondaryDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusMD)),
        child: Padding(
          padding: EdgeInsets.all(spaceMD),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Clear chat?",
                style: TextStyle(color: colours.primaryLight, fontSize: textLG, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: spaceXS),
              Text(
                "This clears the current chat. Saved conversations remain available in Chat history."
                style: TextStyle(color: colours.secondaryLight, fontSize: textSM),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: spaceMD),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: ButtonStyle(
                        backgroundColor: WidgetStatePropertyAll(colours.tertiaryDark),
                        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceSM)),
                      ),
                      child: Text(
                        "Cancel",
                        style: TextStyle(color: colours.primaryLight, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  SizedBox(width: spaceXS),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ButtonStyle(
                        backgroundColor: WidgetStatePropertyAll(colours.primaryNegative),
                        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceSM)),
                      ),
                      child: Text(
                        "Clear",
                        style: TextStyle(color: colours.primaryDark, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed == true) aiChatService.clearConversation();
  }

  String _formatTokens(int n) {
    if (n < 1000) return '$n';
    if (n < 100000) return '${(n / 1000).toStringAsFixed(1)}k';
    if (n < 1000000) return '${(n / 1000).round()}k';
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }

  Widget _inputBar() {
    return ValueListenableBuilder<bool>(
      valueListenable: aiChatService.isStreaming,
      builder: (context, isStreaming, _) {
        return Container(
          decoration: BoxDecoration(color: colours.primaryDark,
            border: Border(top: BorderSide(color: colours.tertiaryDark.withValues(alpha: 0.55)))),
          child: SafeArea(
            top: false,
            child: Container(
              margin: EdgeInsets.fromLTRB(spaceMD, spaceXS, spaceMD, spaceXS),
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                  colors: [colours.tertiaryDark, colours.secondaryDark]),
                borderRadius: BorderRadius.all(cornerRadiusMD),
                border: Border.all(color: colours.primaryLight.withValues(alpha: 0.06)),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 16, offset: Offset(0, 5))],
              ),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _inputController,
                        focusNode: _focusNode,
                        enabled: !isStreaming,
                        style: _mono.merge(TextStyle(color: colours.primaryLight, fontSize: textSM)),
                        maxLines: 4,
                        minLines: 1,
                        decoration: InputDecoration(
                          hintText: 'Ask about this repository…',
                          hintStyle: TextStyle(color: colours.secondaryLight, fontSize: textSM),
                          prefixIcon: Padding(padding: EdgeInsets.all(spaceSM),
                            child: FaIcon(FontAwesomeIcons.message, color: colours.tertiaryInfo, size: textSM)),
                          prefixIconConstraints: BoxConstraints(minWidth: spaceXL, minHeight: spaceXL),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: spaceSM, vertical: spaceSM),
                        ),
                        onChanged: (value) => setState(() => _hasDraft = value.trim().isNotEmpty),
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: GestureDetector(
                        onTap: isStreaming ? () => _confirmStop(context) : _sendMessage,
                        child: Container(
                          margin: EdgeInsets.all(spaceXXS),
                          padding: EdgeInsets.all(spaceSM),
                          decoration: BoxDecoration(
                            gradient: isStreaming
                                ? null
                                : LinearGradient(colors: _hasDraft ? [colours.tertiaryInfo, colours.primaryPositive] : [colours.tertiaryDark, colours.tertiaryDark]),
                            color: isStreaming ? colours.primaryNegative : null,
                            borderRadius: BorderRadius.all(cornerRadiusSM),
                            boxShadow: _hasDraft && !isStreaming ? [BoxShadow(color: colours.tertiaryInfo.withValues(alpha: 0.28), blurRadius: 12)] : const [],
                          ),
                          child: FaIcon(
                            isStreaming ? FontAwesomeIcons.stop : FontAwesomeIcons.solidPaperPlane,
                            color: colours.primaryDark,
                            size: textSM,
                          ),
                        ),
                      ),
                    ),
                    ValueListenableBuilder<List<ChatMessage>>(
                      valueListenable: aiChatService.messages,
                      builder: (context, messages, _) {
                        if (messages.isEmpty) return const SizedBox.shrink();
                        return ValueListenableBuilder<TokenUsage>(
                          valueListenable: aiChatService.sessionUsage,
                          builder: (context, usage, _) {
                            final disabled = isStreaming;
                            final fg = disabled ? colours.secondaryLight : colours.primaryNegative;
                            return Padding(
                              padding: EdgeInsets.all(spaceXXS),
                              child: TextButton.icon(
                                onPressed: disabled ? null : () => _confirmClearChat(context),
                                style: ButtonStyle(
                                  backgroundColor: WidgetStatePropertyAll(Colors.transparent),
                                  overlayColor: WidgetStatePropertyAll(fg.withValues(alpha: 0.1)),
                                  shape: WidgetStatePropertyAll(
                                    RoundedRectangleBorder(
                                      borderRadius: BorderRadius.all(cornerRadiusSM),
                                      side: BorderSide(color: fg),
                                    ),
                                  ),
                                  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: spaceSM)),
                                  minimumSize: WidgetStatePropertyAll(Size.zero),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  iconColor: WidgetStatePropertyAll(fg),
                                ),
                                icon: FaIcon(FontAwesomeIcons.trashCan, color: fg, size: textSM),
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      "Clear",
                                      style: _mono.merge(TextStyle(color: fg, fontSize: textXS, fontWeight: FontWeight.bold)),
                                    ),
                                    SizedBox(width: spaceXXS),
                                    Text(
                                      _formatTokens(usage.inputTokens + usage.outputTokens),
                                      style: _mono.merge(TextStyle(color: fg.withValues(alpha: 0.7), fontSize: textXS)),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AmbientBackdrop extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [colours.primaryDark, colours.darkMode ? Color(0xFF101C2A) : Color(0xFFF1F7FD), colours.primaryDark],
                stops: [0, 0.52, 1],
              ),
            ),
          ),
          Positioned(top: -100, right: -100, child: _ambientGlow(colours.tertiaryInfo, 330)),
          Positioned(bottom: 80, left: -190, child: _ambientGlow(colours.primaryPositive, 360)),
          Positioned(bottom: -240, right: -120, child: _ambientGlow(colours.showcaseBtnPrimary, 440)),
          CustomPaint(
            painter: _AmbientGridPainter(colours.tertiaryInfo.withValues(alpha: 0.035)),
            size: Size.infinite,
          ),
        ],
      ),
    );
  }

  Widget _ambientGlow(Color color, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color.withValues(alpha: 0.14), color.withValues(alpha: 0)]),
      ),
    );
  }
}

class _AmbientGridPainter extends CustomPainter {
  final Color color;
  _AmbientGridPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()..color = color..strokeWidth = 0.55;
    final dot = Paint()..color = color.withValues(alpha: 0.75);
    const step = 34.0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
      for (double x = 0; x <= size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 0.75, dot);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AmbientGridPainter oldDelegate) => oldDelegate.color != color;
}

class _PulsingBrandMark extends StatefulWidget {
  final double size;
  const _PulsingBrandMark({required this.size});

  @override
  State<_PulsingBrandMark> createState() => _PulsingBrandMarkState();
}

class _PulsingBrandMarkState extends State<_PulsingBrandMark> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: Duration(milliseconds: 5200))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final pulse = 0.98 + math.sin(_controller.value * math.pi * 2) * 0.025;
        final radius = widget.size * 0.34;
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Transform.rotate(
                angle: _controller.value * math.pi * 2,
                child: SizedBox(
                  width: widget.size * 0.94,
                  height: widget.size * 0.94,
                  child: Stack(children: [
                    Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: colours.tertiaryInfo.withValues(alpha: 0.28), width: 1),
                    ))),
                    Positioned(right: widget.size * 0.08, top: widget.size * 0.11,
                      child: Container(width: widget.size * 0.13, height: widget.size * 0.13,
                        decoration: BoxDecoration(color: colours.primaryPositive, shape: BoxShape.circle,
                          boxShadow: [BoxShadow(color: colours.primaryPositive.withValues(alpha: 0.75), blurRadius: widget.size * 0.16)]))),
                  ]),
                ),
              ),
              Transform.scale(
                scale: pulse,
                child: Container(
                  width: widget.size * 0.68,
                  height: widget.size * 0.68,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [colours.tertiaryInfo, colours.showcaseBtnPrimary, colours.primaryPositive]),
                    borderRadius: BorderRadius.all(Radius.circular(radius)),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.28), width: 1),
                    boxShadow: [BoxShadow(color: colours.tertiaryInfo.withValues(alpha: 0.18 + (_controller.value * 0.12)), blurRadius: widget.size * 0.42, spreadRadius: 1)],
                  ),
                  child: Icon(FontAwesomeIcons.wandMagicSparkles, color: colours.primaryDark, size: widget.size * 0.31),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AnimatedDots extends StatefulWidget {
  @override
  State<_AnimatedDots> createState() => _AnimatedDotsState();
}

class _AnimatedDotsState extends State<_AnimatedDots> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: EdgeInsets.only(right: spaceXXS),
                child: Opacity(
                  opacity: ((t * 3 - i).clamp(0.0, 1.0) - (t * 3 - i - 1.5).clamp(0.0, 1.0)).abs().clamp(0.3, 1.0),
                  child: Container(
                    width: spaceXS,
                    height: spaceXS,
                    decoration: BoxDecoration(color: colours.tertiaryInfo, shape: BoxShape.circle),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _UninitializedPage extends ConsumerStatefulWidget {
  final VoidCallback onSubscribe;
  const _UninitializedPage({required this.onSubscribe});

  @override
  ConsumerState<_UninitializedPage> createState() => _UninitializedPageState();
}

class _UninitializedPageState extends ConsumerState<_UninitializedPage> {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: colours.primaryDark,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _AmbientBackdrop(),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(height: spaceMD),
                _PulsingBrandMark(size: 88),
                SizedBox(height: spaceSM),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('RepoSync', style: TextStyle(color: colours.primaryLight, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: -0.7)),
                  SizedBox(width: spaceXS),
                  Container(padding: EdgeInsets.symmetric(horizontal: spaceXS, vertical: spaceXXS),
                    decoration: BoxDecoration(gradient: LinearGradient(colors: [colours.tertiaryInfo, colours.primaryPositive]),
                      borderRadius: BorderRadius.all(cornerRadiusXS)),
                    child: Text('AI', style: TextStyle(color: colours.primaryDark, fontSize: textXS, fontWeight: FontWeight.w900))),
                ]),
                SizedBox(height: spaceXXS),
                Text(
                  "Your repo’s new co-pilot",
                  style: TextStyle(color: colours.secondaryLight, fontSize: textMD),
                ),
                SizedBox(height: spaceLG),
                Flexible(
                  child: ShaderMask(
                    shaderCallback: (Rect rect) {
                      return LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.transparent, Colors.transparent, Colors.black],
                        stops: [0, 0.05, 0.95, 1.0],
                      ).createShader(rect);
                    },
                    blendMode: BlendMode.dstOut,
                    child: SingleChildScrollView(
                      padding: EdgeInsets.symmetric(horizontal: spaceMD),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _featureRow(FontAwesomeIcons.codeCommit, "Smart Commits", "Auto-generate meaningful commit messages from your changes"),
                          SizedBox(height: spaceSM),
                          _featureRow(FontAwesomeIcons.codeBranch, "Conflict Resolution", "Resolve merge conflicts with context-aware suggestions"),
                          SizedBox(height: spaceSM),
                          _featureRow(FontAwesomeIcons.filePen, "Code Editing", "Edit files, add headers, refactor code — all from chat"),
                          SizedBox(height: spaceSM),
                          _featureRow(FontAwesomeIcons.filter, "LFS & Filters", "Set up Git LFS, git-crypt, and .gitignore rules instantly"),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(height: spaceMD),
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [colours.tertiaryInfo, colours.primaryPositive]),
                    borderRadius: BorderRadius.all(cornerRadiusSM),
                    boxShadow: [BoxShadow(color: colours.tertiaryInfo.withValues(alpha: 0.23), blurRadius: 22, offset: Offset(0, 8))],
                  ),
                  child: TextButton(
                    onPressed: () => _showByokDialog(context),
                    style: ButtonStyle(
                      backgroundColor: WidgetStatePropertyAll(Colors.transparent),
                      overlayColor: WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.12)),
                      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceSM)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FaIcon(FontAwesomeIcons.key, color: colours.primaryDark, size: textMD),
                        SizedBox(width: spaceXS),
                        Text(
                          "Connect API Key",
                          style: TextStyle(color: colours.primaryDark, fontSize: textMD, fontWeight: FontWeight.w900),
                        ),
                        SizedBox(width: spaceXS),
                        FaIcon(FontAwesomeIcons.arrowRight, color: colours.primaryDark, size: textSM),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: spaceMD),
                Text(
                  "AI-generated content may not always be accurate and should be reviewed before use.",
                  style: TextStyle(color: colours.secondaryLight.withValues(alpha: 0.5), fontSize: textXS),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: spaceSM),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => _showHideAiDialog(context),
                    style: ButtonStyle(
                      backgroundColor: WidgetStatePropertyAll(Colors.transparent),
                      shape: WidgetStatePropertyAll(
                        RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(cornerRadiusSM),
                          side: BorderSide(color: colours.tertiaryDark),
                        ),
                      ),
                      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceSM)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FaIcon(FontAwesomeIcons.eyeSlash, color: colours.secondaryLight, size: textMD),
                        SizedBox(width: spaceXS),
                        Text(
                          t.hideAiFeatures,
                          style: TextStyle(color: colours.secondaryLight, fontSize: textMD, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: spaceLG),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showHideAiDialog(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => BaseAlertDialog(
        title: Text(
          t.hideAiFeaturesConfirmTitle,
          style: TextStyle(color: colours.primaryLight, fontSize: textXL, fontWeight: FontWeight.bold),
        ),
        content: Text(
          t.hideAiFeaturesConfirmMsg,
          style: TextStyle(color: colours.primaryLight, fontSize: textSM),
        ),
        actions: [
          TextButton(
            child: Text(
              t.cancel.toUpperCase(),
              style: TextStyle(color: colours.primaryLight, fontSize: textMD),
            ),
            onPressed: () => Navigator.pop(dialogContext, false),
          ),
          TextButton(
            child: Text(
              t.hideAiFeatures.toUpperCase(),
              style: TextStyle(color: colours.tertiaryNegative, fontSize: textMD),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(aiFeaturesEnabledProvider.notifier).set(false);
    }
  }

  void _showByokDialog(BuildContext context) async {
    final apiKeyController = TextEditingController();
    final endpointController = TextEditingController();
    final dialogScrollController = ScrollController();
    String? selectedProvider;
    String? selectedChatModel;
    String? selectedToolModel;
    String? selectedWandModel;
    List<String> availableModels = [];
    bool loadingModels = false;
    bool loading = false;
    String? error;
    String? modelFetchError;
    Timer? fetchDebounce;
    bool dialogOpen = true;
    void Function(void Function())? safeSetState;

    void tryFetchModels() {
      fetchDebounce?.cancel();
      if (!dialogOpen || selectedProvider == null || apiKeyController.text.trim().isEmpty || loadingModels) return;
      fetchDebounce = Timer(const Duration(milliseconds: 800), () async {
        if (!dialogOpen) return;
        safeSetState?.call(() {
          loadingModels = true;
        });
        final provider = aiProviderFromString(selectedProvider);
        if (provider != null) {
          final apiKey = apiKeyController.text.trim();
          final endpoint = selectedProvider == "Self-hosted" ? endpointController.text.trim() : null;
          final (models, fetchError) = await fetchAvailableModels(provider: provider, apiKey: apiKey, endpoint: endpoint);
          if (!dialogOpen) return;
          availableModels = models;
          modelFetchError = fetchError;
          if (availableModels.isNotEmpty) {
            selectedChatModel = availableModels.first;
            selectedToolModel = availableModels.first;
            selectedWandModel = availableModels.first;
          }
        }
        safeSetState?.call(() {
          loadingModels = false;
        });
        if (modelFetchError != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (dialogScrollController.hasClients) {
              dialogScrollController.animateTo(
                dialogScrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
              );
            }
          });
        }
      });
    }

    final connected = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          safeSetState = (fn) {
            if (dialogOpen) setDialogState(fn);
          };
          final canConnect =
              selectedProvider != null &&
              apiKeyController.text.trim().isNotEmpty &&
              selectedChatModel != null &&
              selectedToolModel != null &&
              selectedWandModel != null &&
              !loading &&
              !loadingModels;

          return Dialog(
            backgroundColor: colours.secondaryDark,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusMD)),
            child: Padding(
              padding: EdgeInsets.all(spaceMD),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      FaIcon(FontAwesomeIcons.key, color: colours.tertiaryInfo, size: textLG),
                      SizedBox(width: spaceXS),
                      Text(
                        "Bring Your Own Key",
                        style: TextStyle(color: colours.primaryLight, fontSize: textLG, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  SizedBox(height: spaceXS),
                  Text(
                    "Repository content is sent to the provider you choose when AI tools read files. Common credential paths are blocked and some token patterns are redacted, but review sensitive code before sharing.",
                    style: TextStyle(color: colours.secondaryLight, fontSize: textXS),
                  ),
                  SizedBox(height: spaceMD),
                  Text(
                    "Provider",
                    style: TextStyle(color: colours.secondaryLight, fontSize: textSM, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: spaceXS),
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(horizontal: spaceSM),
                    decoration: BoxDecoration(color: colours.tertiaryDark, borderRadius: BorderRadius.all(cornerRadiusSM)),
                    child: DropdownButton<String>(
                      value: selectedProvider,
                      isExpanded: true,
                      dropdownColor: colours.secondaryDark,
                      underline: SizedBox.shrink(),
                      hint: Text(
                        "Select a provider",
                        style: TextStyle(color: colours.secondaryLight, fontSize: textSM),
                      ),
                      style: TextStyle(color: colours.primaryLight, fontSize: textSM, fontWeight: FontWeight.bold),
                      items: [
                        for (final p in [
                          ("Anthropic", FontAwesomeIcons.claude),
                          ("OpenAI", FontAwesomeIcons.openai),
                          ("Google", FontAwesomeIcons.google),
                          ("Self-hosted", FontAwesomeIcons.server),
                        ])
                          DropdownMenuItem(
                            value: p.$1,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FaIcon(p.$2, color: colours.secondaryLight, size: textSM),
                                SizedBox(width: spaceXS),
                                Text(p.$1),
                              ],
                            ),
                          ),
                      ],
                      onChanged: loading
                          ? null
                          : (name) {
                              safeSetState?.call(() {
                                selectedProvider = name;
                                availableModels = [];
                                selectedChatModel = null;
                                selectedToolModel = null;
                                selectedWandModel = null;
                                modelFetchError = null;
                              });
                              if (name != null && apiKeyController.text.trim().isNotEmpty) {
                                tryFetchModels();
                              }
                            },
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      controller: dialogScrollController,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(height: spaceMD),
                          if (selectedProvider == "Self-hosted") ...[
                            Text(
                              "Public endpoints require HTTPS. HTTP is allowed only for localhost or a private network.",
                              style: TextStyle(color: colours.secondaryLight, fontSize: textXS),
                            ),
                            SizedBox(height: spaceXS),
                            Text(
                              "Endpoint URL",
                              style: TextStyle(color: colours.secondaryLight, fontSize: textSM, fontWeight: FontWeight.bold),
                            ),
                            SizedBox(height: spaceXS),
                            TextField(
                              controller: endpointController,
                              style: _mono.merge(TextStyle(color: colours.primaryLight, fontSize: textSM)),
                              decoration: InputDecoration(
                                hintText: "your-server.com/v1",
                                hintStyle: _mono.merge(TextStyle(color: colours.secondaryLight, fontSize: textSM)),
                                filled: true,
                                fillColor: colours.tertiaryDark,
                                border: OutlineInputBorder(borderRadius: BorderRadius.all(cornerRadiusSM), borderSide: BorderSide.none),
                                contentPadding: EdgeInsets.symmetric(horizontal: spaceSM, vertical: spaceSM),
                              ),
                            ),
                            SizedBox(height: spaceSM),
                          ],
                          Text(
                            "API Key",
                            style: TextStyle(color: colours.secondaryLight, fontSize: textSM, fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: spaceXS),
                          TextField(
                            controller: apiKeyController,
                            obscureText: true,
                            onChanged: (_) {
                              safeSetState?.call(() {
                                modelFetchError = null;
                              });
                              if (availableModels.isEmpty) tryFetchModels();
                            },
                            style: _mono.merge(TextStyle(color: colours.primaryLight, fontSize: textSM)),
                            decoration: InputDecoration(
                              hintText: selectedProvider == null ? "Select a provider first" : "sk-...",
                              hintStyle: _mono.merge(TextStyle(color: colours.secondaryLight, fontSize: textSM)),
                              filled: true,
                              fillColor: colours.tertiaryDark,
                              border: OutlineInputBorder(borderRadius: BorderRadius.all(cornerRadiusSM), borderSide: BorderSide.none),
                              contentPadding: EdgeInsets.symmetric(horizontal: spaceSM, vertical: spaceSM),
                            ),
                            enabled: selectedProvider != null && !loading,
                          ),
                          SizedBox(height: spaceSM),
                          Row(
                            children: [
                              Text(
                                "Models",
                                style: TextStyle(color: colours.secondaryLight, fontSize: textSM, fontWeight: FontWeight.bold),
                              ),
                              SizedBox(width: spaceXS),
                              if (loadingModels)
                                SizedBox(
                                  width: textSM,
                                  height: textSM,
                                  child: CircularProgressIndicator(strokeWidth: 1.5, color: colours.secondaryLight),
                                ),
                            ],
                          ),
                          SizedBox(height: spaceXS),
                          if (availableModels.isEmpty && !loadingModels)
                            GestureDetector(
                              onTap: (selectedProvider != null && apiKeyController.text.trim().isNotEmpty && !loadingModels)
                                  ? () async {
                                      safeSetState?.call(() {
                                        loadingModels = true;
                                      });
                                      final provider = aiProviderFromString(selectedProvider);
                                      if (provider != null) {
                                        final apiKey = apiKeyController.text.trim();
                                        final endpoint = selectedProvider == "Self-hosted" ? endpointController.text.trim() : null;
                                        final (models, fetchError) = await fetchAvailableModels(
                                          provider: provider,
                                          apiKey: apiKey,
                                          endpoint: endpoint,
                                        );
                                        if (!dialogOpen) return;
                                        availableModels = models;
                                        modelFetchError = fetchError;
                                        if (availableModels.isNotEmpty) {
                                          selectedChatModel = availableModels.first;
                                          selectedToolModel = availableModels.first;
                                          selectedWandModel = availableModels.first;
                                        }
                                      }
                                      safeSetState?.call(() {
                                        loadingModels = false;
                                      });
                                      if (modelFetchError != null) {
                                        WidgetsBinding.instance.addPostFrameCallback((_) {
                                          if (dialogScrollController.hasClients) {
                                            dialogScrollController.animateTo(
                                              dialogScrollController.position.maxScrollExtent,
                                              duration: const Duration(milliseconds: 200),
                                              curve: Curves.easeOut,
                                            );
                                          }
                                        });
                                      }
                                    }
                                  : null,
                              child: Container(
                                width: double.infinity,
                                padding: EdgeInsets.symmetric(horizontal: spaceSM, vertical: spaceSM),
                                decoration: BoxDecoration(color: colours.tertiaryDark, borderRadius: BorderRadius.all(cornerRadiusSM)),
                                child: Text(
                                  selectedProvider == null ? "Select a provider first" : "Tap to load models",
                                  style: _mono.merge(TextStyle(color: colours.secondaryLight, fontSize: textSM)),
                                ),
                              ),
                            )
                          else if (availableModels.isNotEmpty) ...[
                            _byokModelDropdown(
                              label: "Chat",
                              selectedValue: selectedChatModel,
                              availableModels: availableModels,
                              loading: loading,
                              onChanged: (v) => safeSetState?.call(() => selectedChatModel = v),
                            ),
                            SizedBox(height: spaceXS),
                            _byokModelDropdown(
                              label: "Tool",
                              selectedValue: selectedToolModel,
                              availableModels: availableModels,
                              loading: loading,
                              onChanged: (v) => safeSetState?.call(() => selectedToolModel = v),
                            ),
                            SizedBox(height: spaceXS),
                            _byokModelDropdown(
                              label: "Wand",
                              selectedValue: selectedWandModel,
                              availableModels: availableModels,
                              loading: loading,
                              onChanged: (v) => safeSetState?.call(() => selectedWandModel = v),
                            ),
                          ],
                          if (modelFetchError != null) ...[
                            SizedBox(height: spaceXS),
                            Container(
                              width: double.infinity,
                              padding: EdgeInsets.symmetric(horizontal: spaceSM, vertical: spaceXS),
                              decoration: BoxDecoration(
                                color: colours.primaryNegative.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.all(cornerRadiusSM),
                                border: Border.all(color: colours.primaryNegative.withValues(alpha: 0.3)),
                              ),
                              child: Row(
                                children: [
                                  FaIcon(FontAwesomeIcons.circleExclamation, color: colours.primaryNegative, size: textSM),
                                  SizedBox(width: spaceXS),
                                  Expanded(
                                    child: Text(
                                      modelFetchError!,
                                      style: TextStyle(color: colours.primaryNegative, fontSize: textXS, height: 1.4),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (error != null) ...[
                            SizedBox(height: spaceXS),
                            Container(
                              width: double.infinity,
                              padding: EdgeInsets.symmetric(horizontal: spaceSM, vertical: spaceXS),
                              decoration: BoxDecoration(
                                color: colours.primaryNegative.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.all(cornerRadiusSM),
                                border: Border.all(color: colours.primaryNegative.withValues(alpha: 0.3)),
                              ),
                              child: Row(
                                children: [
                                  FaIcon(FontAwesomeIcons.circleExclamation, color: colours.primaryNegative, size: textSM),
                                  SizedBox(width: spaceXS),
                                  Expanded(
                                    child: Text(
                                      error!,
                                      style: TextStyle(color: colours.primaryNegative, fontSize: textXS, height: 1.4),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: spaceMD),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: canConnect
                          ? () async {
                              safeSetState?.call(() {
                                loading = true;
                                error = null;
                              });

                              final provider = aiProviderFromString(selectedProvider);
                              final apiKey = apiKeyController.text.trim();
                              final endpoint = selectedProvider == "Self-hosted" ? endpointController.text.trim() : null;

                              final validationError = await validateAiApiKey(provider: provider!, apiKey: apiKey, endpoint: endpoint);

                              if (!dialogOpen) return;

                              if (validationError != null) {
                                safeSetState?.call(() {
                                  loading = false;
                                  error = validationError;
                                });
                                return;
                              }

                              await repoManager.setStringNullable(StorageKey.repoman_aiProvider, selectedProvider);
                              await repoManager.setStringNullable(StorageKey.repoman_aiApiKey, apiKey);
                              await repoManager.setStringNullable(StorageKey.repoman_aiEndpoint, endpoint);
                              await repoManager.setStringNullable(StorageKey.repoman_aiChatModel, selectedChatModel);
                              await repoManager.setStringNullable(StorageKey.repoman_aiToolModel, selectedToolModel);
                              await repoManager.setStringNullable(StorageKey.repoman_aiWandModel, selectedWandModel);
                              ref.read(aiKeyConfiguredProvider.notifier).state = true;

                              if (!dialogOpen) return;
                              Navigator.pop(context, true);
                            }
                          : null,
                      style: ButtonStyle(
                        backgroundColor: WidgetStatePropertyAll(canConnect ? colours.tertiaryInfo : colours.tertiaryDark),
                        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusSM))),
                        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: spaceSM)),
                      ),
                      child: loading
                          ? SizedBox(
                              height: textMD,
                              width: textMD,
                              child: CircularProgressIndicator(strokeWidth: 2, color: colours.primaryDark),
                            )
                          : Text(
                              "Connect",
                              style: TextStyle(
                                color: canConnect ? colours.primaryDark : colours.secondaryLight,
                                fontSize: textMD,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                  SizedBox(height: spaceXS),
                  Text(
                    "Your API key is stored on this device and sent only to the AI provider you selected, not to RepoSync AI servers.",
                    style: TextStyle(color: colours.secondaryLight, fontSize: textXS, height: 1.4),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    dialogOpen = false;
    fetchDebounce?.cancel();

    if (connected == true) {
      widget.onSubscribe();
    }
  }

  Widget _byokModelDropdown({
    required String label,
    required String? selectedValue,
    required List<String> availableModels,
    required bool loading,
    required void Function(String?) onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: spaceXL,
          child: Text(
            label,
            style: TextStyle(color: colours.secondaryLight, fontSize: textSM),
          ),
        ),
        SizedBox(width: spaceXS),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(horizontal: spaceSM),
            decoration: BoxDecoration(color: colours.tertiaryDark, borderRadius: BorderRadius.all(cornerRadiusSM)),
            child: DropdownButton<String>(
              value: selectedValue,
              isExpanded: true,
              dropdownColor: colours.secondaryDark,
              underline: SizedBox.shrink(),
              style: _mono.merge(TextStyle(color: colours.primaryLight, fontSize: textSM)),
              items: availableModels
                  .map(
                    (m) => DropdownMenuItem(
                      value: m,
                      child: Text(m, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: loading ? null : onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _featureRow(FaIconData icon, String title, String description) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(spaceSM),
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [colours.secondaryDark.withValues(alpha: 0.86), colours.secondaryDark.withValues(alpha: 0.58)]),
        borderRadius: BorderRadius.all(cornerRadiusSM),
        border: Border.all(color: colours.tertiaryInfo.withValues(alpha: 0.12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: spaceLG,
            height: spaceLG,
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [colours.tertiaryInfo.withValues(alpha: 0.23), colours.primaryPositive.withValues(alpha: 0.08)]),
              borderRadius: BorderRadius.all(cornerRadiusSM),
              border: Border.all(color: colours.tertiaryInfo.withValues(alpha: 0.16)),
            ),
            child: Center(child: FaIcon(icon, color: colours.tertiaryInfo, size: textMD)),
          ),
          SizedBox(width: spaceSM),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: colours.primaryLight, fontSize: textMD, fontWeight: FontWeight.w800)),
                SizedBox(height: spaceXXXS),
                Text(description, style: TextStyle(color: colours.secondaryLight, fontSize: textSM, height: 1.4)),
              ],
            ),
          ),
          SizedBox(width: spaceXS),
          FaIcon(FontAwesomeIcons.circleCheck, color: colours.primaryPositive.withValues(alpha: 0.7), size: textSM),
        ],
      ),
    );
  }
}

void _openLink(String url) {
  final uri = Uri.tryParse(url.startsWith(RegExp(r'[a-z][a-z0-9+.-]*:', caseSensitive: false)) ? url : 'https://$url');
  if (uri == null) return;
  launchUrl(uri, mode: LaunchMode.externalApplication);
}

class _LinkifiedText extends StatefulWidget {
  const _LinkifiedText(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<_LinkifiedText> {
  final List<TapGestureRecognizer> _recognizers = [];

  void _clearRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();

    final linkStyle = widget.style.merge(TextStyle(color: colours.tertiaryInfo, decoration: TextDecoration.underline));
    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in _urlRegex.allMatches(widget.text)) {
      var url = match.group(0)!;
      while (url.isNotEmpty && '.,;:!?\')]}'.contains(url[url.length - 1])) {
        url = url.substring(0, url.length - 1);
      }
      if (url.isEmpty) continue;

      if (match.start > cursor) spans.add(TextSpan(text: widget.text.substring(cursor, match.start)));

      final recognizer = TapGestureRecognizer()..onTap = () => _openLink(url);
      _recognizers.add(recognizer);
      spans.add(TextSpan(text: url, style: linkStyle, recognizer: recognizer));
      cursor = match.start + url.length;
    }

    if (cursor < widget.text.length) spans.add(TextSpan(text: widget.text.substring(cursor)));

    return Text.rich(TextSpan(children: spans), style: widget.style);
  }
}
