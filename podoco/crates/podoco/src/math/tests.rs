use super::*;
use crate::{ErrorCode, results::FormulaDisplayKind};

#[test]
fn strict_conversion_preserves_source_and_rejects_unsupported_math() {
    let rules = MathRules::testing();
    let input = MathInput::latex("$x^2 + 2$", FormulaDisplayKind::Unknown);
    let output = convert::run(input.clone(), MathLimits::default(), &rules).unwrap();
    assert_eq!(input.text, "$x^2 + 2$");
    assert_eq!(output.display_kind, FormulaDisplayKind::Inline);
    assert_eq!(output.diagnostics.len(), 2);
    assert!(output.mathml.contains("<msup>"));
    for text in [r"\unknown{x}", r"\frac{", r"\def\x{\x}\x", "$x$ trailing"] {
        let e = convert::run(
            MathInput::latex(text, FormulaDisplayKind::Inline),
            MathLimits::default(),
            &rules,
        )
        .unwrap_err();
        assert_eq!(e.code, ErrorCode::Conversion, "{text}: {e}");
    }
    for text in [
        "<math><mfrac></math>",
        "<math><mfrac><mi>x</mi></mfrac></math>",
        "<math><munder><mi>a</mi><mi>b</mi><mi>c</mi></munder></math>",
        "<!DOCTYPE math><math/>",
        "<math><img src='x'/></math>",
        "<math><mi href='x'>x</mi></math>",
        "<math xmlns='https://example.invalid'><mi>x</mi></math>",
    ] {
        assert_eq!(
            convert::run(
                MathInput::mathml(text, FormulaDisplayKind::Inline),
                MathLimits::default(),
                &rules
            )
            .unwrap_err()
            .code,
            ErrorCode::Conversion
        );
    }
    assert_eq!(
        convert::run(
            MathInput::mathml(
                "<math display='block'><mi>x</mi></math>",
                FormulaDisplayKind::Inline
            ),
            MathLimits::default(),
            &rules
        )
        .unwrap_err()
        .code,
        ErrorCode::InvalidInput
    );
    assert!(
        convert::run(
            MathInput::latex("x", FormulaDisplayKind::Inline),
            MathLimits::default(),
            &rules
        )
        .is_ok()
    );
}

#[test]
fn parser_and_serialization_limits_are_enforced() {
    let rules = MathRules::testing();
    for (text, limits) in [
        ("long", MathLimits::new(1, 1, 4096, 100, 8).unwrap()),
        ("{{{{x}}}}", MathLimits::new(1, 1024, 4096, 100, 3).unwrap()),
        ("x+x+x+x", MathLimits::new(1, 1024, 4096, 2, 8).unwrap()),
        ("x", MathLimits::new(1, 1024, 10, 100, 8).unwrap()),
    ] {
        assert_eq!(
            convert::run(
                MathInput::latex(text, FormulaDisplayKind::Inline),
                limits,
                &rules
            )
            .unwrap_err()
            .code,
            ErrorCode::LimitExceeded
        );
    }
    let output = convert::run(
        MathInput::latex("x", FormulaDisplayKind::Inline),
        MathLimits::default(),
        &rules,
    )
    .unwrap();
    assert_eq!(
        output.to_json(10).unwrap_err().code,
        ErrorCode::LimitExceeded
    );
    let mut options = MathSpeechOptions::new("en", "ClearSpeak");
    options.decimal_separators = ",".into();
    assert_eq!(
        options.validate().unwrap_err().code,
        ErrorCode::InvalidInput
    );
    options.block_separators = ".".into();
    assert!(options.validate().is_ok());
    assert!(MathLimits::new(0, 1, 1, 1, 1).is_err());
    assert!(MathLimits::new(1, 65537, 1, 1, 1).is_err());
}

#[test]
fn rules_reject_missing_changed_and_incomplete_assets() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(
        MathRules::verify(dir.path()).unwrap_err().code,
        ErrorCode::Io
    );
    std::fs::write(dir.path().join("podoco-rules.yaml"), "changed").unwrap();
    assert_eq!(
        MathRules::verify(dir.path()).unwrap_err().code,
        ErrorCode::InvalidManifest
    );
    std::fs::write(dir.path().join("podoco-rules.yaml"), rules::PIN).unwrap();
    assert_eq!(
        MathRules::verify(dir.path()).unwrap_err().code,
        ErrorCode::InvalidAsset
    );
}
