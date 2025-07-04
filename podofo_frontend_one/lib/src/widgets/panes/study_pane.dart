import 'package:shadcn_flutter/shadcn_flutter.dart';

class StudyPane extends StatefulWidget {
  const StudyPane({super.key});

  @override
  State<StudyPane> createState() => _StudyPaneState();
}

class _StudyPaneState extends State<StudyPane> {
  int? _activeIndex;
  bool _isLoading = false;

  void _onButtonPressed(int index) {
    if (_isLoading) return;

    if (_activeIndex == index) {
      setState(() {
        _activeIndex = null;
      });
      return;
    }

    setState(() {
      _activeIndex = index;
      _isLoading = true;
    });

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _activeIndex == index) {
        setState(() {
          _isLoading = false;
        });
      }
    });
  }

  Widget _buildButton(int index, Widget child) {
    final bool isActive = _activeIndex == index;
    final bool isLoading = isActive && _isLoading;

    if (isLoading) {
      final hasSubtitle = (child as Column).children.length > 1;
      return Button(
        style: ButtonStyle.outline(size: ButtonSize.large),
        enabled: false,
        child: SizedBox(
          width: double.infinity,
          height: hasSubtitle ? 64 : 48,
          child: const Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return Button(
      alignment: AlignmentGeometry.topLeft,
      enabled: true,
      style: isActive
          ? ButtonStyle.primary(size: ButtonSize.large)
          : ButtonStyle.outline(size: ButtonSize.large),
      onPressed: () => _onButtonPressed(index),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 5.0,
        children: [
          // const SizedBox(height: 16),
          // Button.card(child: const Text('Study Pane')),
          // const SizedBox(height: 16),
          _buildButton(
            0,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Summarize').x2Large,
                // const Text('Create an executive summary').small,
              ],
            ),
          ),
          _buildButton(
            1,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('FAQ').x2Large,
                const Text('with answer keys').small,
              ],
            ),
          ),
          _buildButton(
            2,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Quiz Mode').x2Large,
                // const Text('Enter Quiz Mode').small,
              ],
            ),
          ),
          _buildButton(
            3,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Anki').x2Large,
                // const Text('Generate flashcards').small,
              ],
            ),
          ),

          // Button(
          //   style: ButtonStyle.outline(size: ButtonSize.large),
          //   child: const Text('Summary'),
          // ),
          // Button(
          //   style: ButtonStyle.primary(size: ButtonSize.xLarge),
          //   child: const Text('Study Pane'),
          // ),
        ],
      ),
    );
  }
}
