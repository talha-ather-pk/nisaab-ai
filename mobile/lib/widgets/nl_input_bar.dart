import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../core/theme.dart';
import 'common.dart';

/// Persistent bottom bar: type or speak a transaction in plain language.
/// Calls [onSubmit] with the text and its source ('text' or 'voice'); when it returns
/// false (e.g. the server was unreachable) the text is put back so nothing is lost.
class NlInputBar extends StatefulWidget {
  const NlInputBar({
    super.key,
    required this.onSubmit,
    required this.onManualAdd,
    this.busy = false,
    this.hint = 'e.g. Spent 1,200 on groceries at Carrefour',
  });

  final Future<bool> Function(String text, String source) onSubmit;
  final VoidCallback onManualAdd;
  final bool busy;
  final String hint;

  @override
  State<NlInputBar> createState() => _NlInputBarState();
}

class _NlInputBarState extends State<NlInputBar> {
  final TextEditingController _ctrl = TextEditingController();
  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;
  bool _listening = false;
  String _source = 'text';

  @override
  void dispose() {
    _speech.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || widget.busy) return;
    FocusScope.of(context).unfocus();
    final source = _source;
    _ctrl.clear();
    _source = 'text';
    final ok = await widget.onSubmit(text, source);
    if (!ok && mounted && _ctrl.text.isEmpty) {
      _ctrl.text = text;
      _source = source;
    }
  }

  Future<void> _toggleMic() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (!_speechReady) {
      _speechReady = await _speech.initialize(
        onStatus: _onStatus,
        onError: (_) {
          if (mounted) setState(() => _listening = false);
        },
      );
      if (!_speechReady) {
        if (mounted) showSnack(context, 'Voice input isn’t available. Check microphone permission.', error: true);
        return;
      }
    }
    _ctrl.clear();
    setState(() => _listening = true);
    await _speech.listen(
      onResult: _onResult,
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenFor: const Duration(seconds: 20),
        pauseFor: const Duration(seconds: 3),
      ),
    );
  }

  void _onStatus(String status) {
    if ((status == 'done' || status == 'notListening') && mounted) {
      setState(() => _listening = false);
    }
  }

  void _onResult(SpeechRecognitionResult result) {
    _source = 'voice';
    _ctrl.value = TextEditingValue(
      text: result.recognizedWords,
      selection: TextSelection.collapsed(offset: result.recognizedWords.length),
    );
    if (result.finalResult) {
      setState(() => _listening = false);
      if (result.recognizedWords.trim().isNotEmpty) _submit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 24, offset: const Offset(0, 8)),
          ],
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Add manually',
              onPressed: widget.busy ? null : widget.onManualAdd,
              icon: Icon(Icons.add_circle_outline, color: colors.primary),
            ),
            Expanded(
              child: TextField(
                controller: _ctrl,
                enabled: !widget.busy,
                textInputAction: TextInputAction.send,
                onChanged: (_) => _source = 'text',
                onSubmitted: (_) => _submit(),
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: _listening ? 'Listening…' : widget.hint,
                  hintStyle: TextStyle(color: context.palette.muted, fontSize: 14),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            IconButton(
              tooltip: _listening ? 'Stop listening' : 'Speak',
              onPressed: widget.busy ? null : _toggleMic,
              icon: Icon(
                _listening ? Icons.stop_circle : Icons.mic_none,
                color: _listening ? context.palette.critical : colors.primary,
              ),
            ),
            SizedBox(
              width: 44,
              height: 44,
              child: widget.busy
                  ? const Padding(padding: EdgeInsets.all(11), child: CircularProgressIndicator(strokeWidth: 2.5))
                  : IconButton.filled(
                      tooltip: 'Send',
                      onPressed: _submit,
                      icon: const Icon(Icons.arrow_upward, size: 20),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
