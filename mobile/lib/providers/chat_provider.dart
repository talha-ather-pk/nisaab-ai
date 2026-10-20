import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_service.dart';
import 'core_providers.dart';
import 'session_provider.dart';

enum ChatRole { user, assistant, error }

class ChatMessage {
  final String id;
  final ChatRole role;
  final String text;
  final String? provider; // rules | claude
  final DateTime time;

  ChatMessage({required this.role, required this.text, this.provider, DateTime? time, String? id})
      : time = time ?? DateTime.now(),
        id = id ?? '${DateTime.now().microsecondsSinceEpoch}-${role.name}';
}

class ChatState {
  final List<ChatMessage> messages;
  final List<String> suggestions;
  final bool sending;
  final bool loadingHistory;
  final String? lastFailedMessage;

  const ChatState({
    this.messages = const [],
    this.suggestions = kStarterPrompts,
    this.sending = false,
    this.loadingHistory = true,
    this.lastFailedMessage,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    List<String>? suggestions,
    bool? sending,
    bool? loadingHistory,
    String? lastFailedMessage,
    bool clearFailed = false,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      suggestions: suggestions ?? this.suggestions,
      sending: sending ?? this.sending,
      loadingHistory: loadingHistory ?? this.loadingHistory,
      lastFailedMessage: clearFailed ? null : (lastFailedMessage ?? this.lastFailedMessage),
    );
  }
}

const List<String> kStarterPrompts = [
  'How much did I spend this month?',
  'Where does most of my money go?',
  'Am I on track with my budgets?',
  'Give me saving tips',
];

class ChatNotifier extends Notifier<ChatState> {
  static const _historyTurns = 10;

  @override
  ChatState build() {
    ref.watch(currentUserProvider);
    Future.microtask(_loadHistory);
    return const ChatState();
  }

  Future<void> _loadHistory() async {
    try {
      final items = await ref.read(apiServiceProvider).assistantHistory(limit: 30);
      final messages = <ChatMessage>[];
      for (final item in items) {
        messages.add(ChatMessage(role: ChatRole.user, text: item.message, time: item.createdAt, id: 'u${item.id}'));
        if (item.reply != null) {
          messages.add(ChatMessage(
            role: ChatRole.assistant,
            text: item.reply!,
            provider: item.provider,
            time: item.createdAt,
            id: 'a${item.id}',
          ));
        }
      }
      state = state.copyWith(messages: messages, loadingHistory: false);
    } on ApiException {
      state = state.copyWith(loadingHistory: false);
    }
  }

  Future<void> send(String text) async {
    final message = text.trim();
    if (message.isEmpty || state.sending) return;

    final history = state.messages
        .where((m) => m.role != ChatRole.error)
        .toList()
        .reversed
        .take(_historyTurns)
        .toList()
        .reversed
        .map((m) => {
              'role': m.role == ChatRole.user ? 'user' : 'assistant',
              'content': m.text.length > 4000 ? m.text.substring(0, 4000) : m.text,
            })
        .toList();

    state = state.copyWith(
      messages: [...state.messages.where((m) => m.role != ChatRole.error), ChatMessage(role: ChatRole.user, text: message)],
      sending: true,
      clearFailed: true,
    );

    try {
      final reply = await ref.read(apiServiceProvider).askAssistant(message, history);
      state = state.copyWith(
        messages: [...state.messages, ChatMessage(role: ChatRole.assistant, text: reply.reply, provider: reply.provider)],
        suggestions: reply.suggestions.isEmpty ? kStarterPrompts : reply.suggestions,
        sending: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(
        messages: [...state.messages, ChatMessage(role: ChatRole.error, text: e.message)],
        sending: false,
        lastFailedMessage: message,
      );
    }
  }

  /// Re-send the last message that failed (drops its user bubble first).
  Future<void> retry() async {
    final failed = state.lastFailedMessage;
    if (failed == null) return;
    final messages = [...state.messages.where((m) => m.role != ChatRole.error)];
    if (messages.isNotEmpty && messages.last.role == ChatRole.user && messages.last.text == failed) {
      messages.removeLast();
    }
    state = state.copyWith(messages: messages, clearFailed: true);
    await send(failed);
  }
}

final chatProvider = NotifierProvider<ChatNotifier, ChatState>(ChatNotifier.new);
