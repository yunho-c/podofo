// import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

// Define a type for the callback that will receive the form values.
// It expects a map where keys are field names (Strings) and values are dynamic.
typedef OnProfileSave = void Function(Map<String, dynamic> values);

/// Provides a utility to show the profile editing dialog.
///
/// Any widget can call `HotkeyEditor.show(context, onSave: ...)` to present
/// the profile editing form.
class HotkeyEditor {
  /// Shows the profile editing dialog.
  ///
  /// [context] is the build context to show the dialog in.
  /// [onSave] is an optional callback that will be invoked when the user
  /// saves the changes, providing the edited values.
  static void show(BuildContext context, {OnProfileSave? onSave}) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        final FormController controller = FormController();
        return AlertDialog(
          title: const Text('Edit profile'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Make changes to your profile here. Click save when you\'re done'),
              const Gap(16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Form(
                  controller: controller,
                  child: FormTableLayout(rows: [
                    FormField<String>(
                      // Use a string literal for the key, and ensure it's const.
                      key: const FormKey<String>('name'),
                      label: const Text('Name'),
                      child: const TextField( // Mark TextField as const
                        initialValue: 'Thito Yalasatria Sunarya',
                      ),
                    ),
                    FormField<String>(
                      // Use a string literal for the key, and ensure it's const.
                      key: const FormKey<String>('username'),
                      label: const Text('Username'),
                      child: const TextField( // Mark TextField as const
                        initialValue: '@sunaryathito',
                      ),
                    ),
                  ]),
                ).withPadding(vertical: 16),
              ),
            ],
          ),
          actions: [
            PrimaryButton(
              child: const Text('Save changes'),
              onPressed: () {
                // FIX: Resolve the type mismatch for controller.values.
                // controller.values returns Map<FormKey<dynamic>, dynamic>.
                // We need a Map<String, dynamic> for the onSave callback and general use.
                final Map<FormKey<dynamic>, dynamic> formValuesWithKeys = controller.values;
                final Map<String, dynamic> profileValues = {};

                formValuesWithKeys.forEach((key, value) {
                  // Assuming FormKey's toString() method correctly returns the field name as a string.
                  // Example: FormKey('username').toString() should yield 'username'.
                  profileValues[key.toString()] = value;
                });

                // If an onSave callback is provided, invoke it with the converted values.
                if (onSave != null) {
                  onSave!(profileValues);
                }

                // Close the dialog. If we want to pass data back to the caller,
                // we pass it here. The 'profileValues' map is already in the desired format.
                Navigator.of(dialogContext).pop(profileValues);
              },
            ),
          ],
        );
      },
    );
  }
}
