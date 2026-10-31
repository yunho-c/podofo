// Appended to MLSR's development-only Core ML probe for this investigation.

#[cfg(feature = "kvo")]
#[unsafe(no_mangle)]
pub extern "C" fn probe_kvo() -> i32 {
    std::panic::catch_unwind(|| {
        cidre::objc::ar_pool(|| {
            use cidre::ns;
            use std::cell::Cell;
            let calls = Cell::new(0);
            let mut queue = ns::OpQueue::new();
            let observer = ns::Observer::with_obj(
                queue.as_mut(),
                ns::str!(c"name"),
                ns::KvoOpts::INITIAL | ns::KvoOpts::NEW,
                |_key, _object, _change| calls.set(calls.get() + 1),
            )
            .unwrap();
            assert_eq!(calls.get(), 1);
            queue.set_name(Some(ns::str!(c"during-observation")));
            assert_eq!(calls.get(), 2);
            drop(observer);
            queue.set_name(Some(ns::str!(c"after-observer-drop")));
            assert_eq!(calls.get(), 2);
            0
        })
    })
    .unwrap_or(-1)
}
