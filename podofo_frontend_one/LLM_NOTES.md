---

  ButtonStatePropertyDelegate<T> is a function type defined as:

   1 typedef ButtonStatePropertyDelegate<T> = T Function(
   2     BuildContext context, Set<WidgetState> states, T value);

  Its primary role is to dynamically resolve a button's property value by delegating the decision to a function that can consider
   the button's current state.

  Here’s a breakdown of its function and usage:

   1. State-Dependent Calculation: It takes the BuildContext, a Set<WidgetState> (which includes states like hovered, focused,
      pressed, disabled), and an existing value of type T. It returns a new or modified value of type T.

   2. Layered Styling and Theming: Its main purpose is to allow for layered and customizable button styling. Instead of just
      defining a static value, you can provide a delegate function that modifies a base style.

   3. Usage in `ButtonTheme`: It is used within ButtonTheme subclasses (e.g., PrimaryButtonTheme, GhostButtonTheme). This allows
      developers to provide custom styling logic in the application's theme that can override the default behavior of a button.
      The delegate receives the button's default resolved property (value) and can return a modified version based on the theme's
       logic.

      For example, in ComponentThemeButtonStyle:

   1     Decoration _resolveDecoration(BuildContext context, Set<WidgetState> states) {
   2       var resolved = fallback.decoration(context, states); // Get the base decoration
   3       // Use the delegate from the theme to potentially override it
   4       return find(context)?.decoration?.call(context, states, resolved) ?? resolved;
   5     }

   4. Usage in `copyWith`: It is also used in the copyWith extension method for AbstractButtonStyle. This allows for creating
      ad-hoc, inline style modifications by providing a delegate function for a specific property.

  In summary, ButtonStatePropertyDelegate is a powerful callback mechanism for the theming system. It enables flexible and
  state-aware customization of button properties by allowing theme-level or instance-level logic to intercept and modify a
  button's base style.

---
