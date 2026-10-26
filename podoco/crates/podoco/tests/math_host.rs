//! Opt-in process-isolated audit of MathCAT's host effects and worker preferences.
#![cfg(feature = "math")]
use podoco::{ErrorCode, math::*, results::FormulaDisplayKind};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

#[test]
#[ignore = "requires explicit PODOCO_M7_RULES; owns this test process's panic hook"]
fn isolated_preferences_and_host_panic_hook_survive_mathcat() {
    let rules =
        MathRules::verify(std::env::var_os("PODOCO_M7_RULES").expect("explicit rules")).unwrap();
    let counter = Arc::new(AtomicUsize::new(0));
    let observed = counter.clone();
    let old = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |_| {
        observed.fetch_add(1, Ordering::SeqCst);
    }));
    let result = std::panic::catch_unwind(|| {
        let first = MathProcessor::open(rules.clone(), MathLimits::default()).unwrap();
        let second = MathProcessor::open(rules, MathLimits::default()).unwrap();
        let input = || MathInput::latex(r"\frac{x+1}{2}", FormulaDisplayKind::Inline);
        let english = MathSpeechOptions::new("en", "ClearSpeak");
        let spanish = MathSpeechOptions::new("es", "SimpleSpeak");
        let expected = first.to_speech(input(), english.clone()).unwrap();
        let translated = second.to_speech(input(), spanish.clone()).unwrap();
        assert_ne!(expected.text, translated.text);
        for _ in 0..3 {
            assert_eq!(
                first.to_speech(input(), spanish.clone()).unwrap().text,
                translated.text
            );
            assert_eq!(
                second.to_speech(input(), english.clone()).unwrap().text,
                expected.text
            );
            assert_eq!(
                first.to_speech(input(), english.clone()).unwrap().text,
                expected.text
            );
        }
        assert_eq!(
            first
                .to_speech(input(), MathSpeechOptions::new("ko", "ClearSpeak"))
                .unwrap_err()
                .code,
            ErrorCode::UnsupportedCapability
        );
        assert_eq!(
            first
                .to_speech(
                    MathInput::latex(r"\unknown{x}", FormulaDisplayKind::Inline),
                    english.clone()
                )
                .unwrap_err()
                .code,
            ErrorCode::Conversion
        );
        assert_eq!(
            first.to_speech(input(), english).unwrap().text,
            expected.text
        );
        first.close().unwrap();
        first.close().unwrap();
        assert_eq!(
            first.to_mathml(input()).unwrap_err().code,
            ErrorCode::InvalidInput
        );
        assert_eq!(
            second.to_speech(input(), spanish).unwrap().text,
            translated.text
        );
        second.close().unwrap();
        assert!(std::panic::catch_unwind(|| panic!("controlled host hook probe")).is_err());
        assert_eq!(
            counter.load(Ordering::SeqCst),
            1,
            "MathCAT replaced the host hook"
        );
    });
    std::panic::set_hook(old);
    result.unwrap();
}
