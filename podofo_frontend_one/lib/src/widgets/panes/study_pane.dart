import 'package:shadcn_flutter/shadcn_flutter.dart';

class StudyPane extends StatelessWidget {
  const StudyPane({super.key});

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
          Button(
            style: ButtonStyle.outline(size: ButtonSize.large),
            onTapDown: (details) => {},
            enabled: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Summarize'),
                const Text('Create an executive summary').small,
              ],
            ),
          ),
          Button(
            style: ButtonStyle.outline(size: ButtonSize.large),
            enabled: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Generate FAQ'),
                const Text('with answer keys').small,
              ],
            ),
          ),
          Button(
            style: ButtonStyle.outline(size: ButtonSize.large),
            enabled: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Quiz Mode'),
                const Text('Enter Quiz Mode').small,
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
