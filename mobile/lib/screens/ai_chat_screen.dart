import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../providers/chat_provider.dart';
import '../widgets/common.dart';
import 'home_shell.dart';

class AiChatScreen extends ConsumerStatefulWidget {
  const AiChatScreen({super.key});

  @override
  ConsumerState<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends ConsumerState<AiChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send([String? preset]) {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty) return;
    _input.clear();
    ref.read(chatProvider.notifier).send(text);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    ref.listen(chatProvider.select((s) => s.messages.length), (_, __) => _scrollToBottom());

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.auto_awesome),
            SizedBox(width: 8),
            Flexible(
              child: Text('Assistant',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
        actions: const [ProfileButton()],
      ),
      body: Column(
        children: [
          Expanded(
            child: chat.loadingHistory
                ? const Center(child: CircularProgressIndicator())
                : chat.messages.isEmpty
                    ? _Intro(onPick: _send)
                    : ListView.builder(
                        controller: _scroll,
                        reverse: true, // newest at the bottom, keyboard-friendly
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        itemCount: chat.messages.length + (chat.sending ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (chat.sending && index == 0) return const _TypingBubble();
                          final i = chat.messages.length - 1 - (index - (chat.sending ? 1 : 0));
                          final message = chat.messages[i];
                          return _Bubble(
                            message: message,
                            onRetry: message.role == ChatRole.error ? ref.read(chatProvider.notifier).retry : null,
                          );
                        },
                      ),
          ),
          if (chat.messages.isNotEmpty && !chat.sending)
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: chat.suggestions.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => ActionChip(
                  label: Text(chat.suggestions[i]),
                  onPressed: () => _send(chat.suggestions[i]),
                ),
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 1000,
                      enabled: !chat.sending,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Ask about your spending, budgets or savings…',
                        counterText: '',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Send',
                    onPressed: chat.sending ? null : _send,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro({required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 24),
        Icon(Icons.auto_awesome, size: 48, color: context.colors.primary),
        const SizedBox(height: 12),
        Text('Ask me about your money', textAlign: TextAlign.center,
            style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
          'I read your own transactions, budgets and forecast to answer. English or Roman Urdu both work.',
          textAlign: TextAlign.center,
          style: TextStyle(color: context.palette.muted),
        ),
        const SizedBox(height: 24),
        for (final prompt in kStarterPrompts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton(
              onPressed: () => onPick(prompt),
              style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft, padding: const EdgeInsets.all(14)),
              child: Text(prompt),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          'General guidance only, not licensed financial advice.',
          textAlign: TextAlign.center,
          style: TextStyle(color: context.palette.muted, fontSize: 12),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, this.onRetry});

  final ChatMessage message;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isUser = message.role == ChatRole.user;
    final isError = message.role == ChatRole.error;
    final bg = isUser
        ? colors.primary
        : isError
            ? context.palette.critical.withValues(alpha: 0.12)
            : colors.surfaceContainerHighest;
    final fg = isUser ? colors.onPrimary : (isError ? context.palette.critical : colors.onSurface);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onLongPress: () {
                  Clipboard.setData(ClipboardData(text: message.text));
                  showSnack(context, 'Copied');
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: Radius.circular(isUser ? 18 : 4),
                      bottomRight: Radius.circular(isUser ? 4 : 18),
                    ),
                  ),
                  child: Text(message.text, style: TextStyle(color: fg, height: 1.35)),
                ),
              ),
              const SizedBox(height: 3),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    [
                      DateFormat('h:mm a').format(message.time),
                      if (message.provider == 'claude') 'Claude',
                      if (message.provider == 'rules') 'Nisaab insights',
                    ].join(' · '),
                    style: TextStyle(fontSize: 11, color: context.palette.muted),
                  ),
                  if (onRetry != null) ...[
                    const SizedBox(width: 8),
                    TextButton(onPressed: onRetry, child: const Text('Retry')),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        label: 'Assistant is typing',
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: context.colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(18),
          ),
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final t = ((_c.value * 3) - i).clamp(0.0, 1.0);
                final opacity = 0.3 + 0.7 * (1 - (t - 0.5).abs() * 2).clamp(0.0, 1.0);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Opacity(
                    opacity: opacity,
                    child: CircleAvatar(radius: 4, backgroundColor: context.palette.muted),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}
