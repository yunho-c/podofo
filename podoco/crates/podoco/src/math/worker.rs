use super::{convert, types::conversion, *};
use crate::{Error, ErrorCode, Result};
use std::{
    collections::VecDeque,
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc, Condvar, Mutex,
        mpsc::{self, SyncSender},
    },
    thread::JoinHandle,
};

enum Output {
    Mathml(MathConversion),
    Speech(MathSpeech),
}
type Operation = Box<dyn FnMut(MathInput, Option<MathSpeechOptions>) -> Result<Output> + Send>;
struct Request {
    input: MathInput,
    speech: Option<MathSpeechOptions>,
    reply: SyncSender<Result<Output>>,
}
#[derive(Default)]
struct State {
    closed: bool,
    failure: Option<Error>,
    requests: VecDeque<Request>,
}
struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}
/// Independent bounded conversion lane. One worker owns all MathCAT thread-local
/// expression/preferences state. Blocking calls and close belong off UI threads.
pub struct MathProcessor {
    shared: Arc<Shared>,
    worker: Mutex<Option<JoinHandle<()>>>,
    limits: MathLimits,
    rules: MathRules,
    languages: Vec<MathLanguage>,
}
impl MathProcessor {
    /// Open an isolated processor from verified rules, without any ML/TTS model.
    pub fn open(rules: MathRules, limits: MathLimits) -> Result<Self> {
        let worker_rules = rules.clone();
        Self::start(rules, limits, move || {
            let path = worker_rules.directory().join("Rules");
            libmathcat::set_rules_dir(
                path.to_str()
                    .ok_or_else(|| Error::input("MathCAT rule path is not UTF-8"))?,
            )
            .map_err(mathcat_error)?;
            let mut languages = Vec::new();
            for language in libmathcat::get_supported_languages().map_err(mathcat_error)? {
                // v1 exposes base languages with explicit local style files.
                // Regional fallback behavior needs separate qualification.
                if language.contains('-') {
                    continue;
                }
                let speech_styles =
                    libmathcat::get_supported_speech_styles(&language).map_err(mathcat_error)?;
                if !speech_styles.is_empty() {
                    languages.push(MathLanguage {
                        language,
                        speech_styles,
                    });
                }
            }
            let supported = languages.clone();
            let operation: Operation = Box::new(move |input, speech| {
                let converted = convert::run(input, limits, &worker_rules)?;
                if let Some(options) = speech {
                    if !supported.iter().any(|l| {
                        l.language == options.language
                            && l.speech_styles.contains(&options.speech_style)
                    }) {
                        return Err(Error::new(
                            ErrorCode::UnsupportedCapability,
                            "math language/style is not in the verified supported set",
                        ));
                    }
                    // Every setting exposed by this API, plus fixed plain-text
                    // behavior, is applied before the expression is installed.
                    let verbosity = format!("{:?}", options.verbosity);
                    for (name, value) in [
                        ("Language", options.language.as_str()),
                        ("SpeechStyle", options.speech_style.as_str()),
                        ("Verbosity", verbosity.as_str()),
                        ("DecimalSeparators", options.decimal_separators.as_str()),
                        ("BlockSeparators", options.block_separators.as_str()),
                        ("TTS", "None"),
                        ("Bookmark", "false"),
                        ("CheckRuleFiles", "None"),
                        ("IntentErrorRecovery", "Error"),
                    ] {
                        libmathcat::set_preference(name, value).map_err(mathcat_error)?;
                    }
                    if libmathcat::get_preference("Language").map_err(mathcat_error)?
                        != options.language
                        || libmathcat::get_preference("SpeechStyle").map_err(mathcat_error)?
                            != options.speech_style
                    {
                        return Err(conversion("MathCAT changed the requested language/style"));
                    }
                    let canonical =
                        libmathcat::set_mathml(&converted.mathml).map_err(mathcat_error)?;
                    if canonical.len() > limits.output_bytes() as usize {
                        return Err(types::limit("canonical MathML exceeds output limit"));
                    }
                    let text = libmathcat::get_spoken_text().map_err(mathcat_error)?;
                    if text.trim().is_empty() {
                        return Err(conversion("MathCAT returned empty speech"));
                    }
                    if text.len() > limits.output_bytes() as usize {
                        return Err(types::limit("math speech exceeds output limit"));
                    }
                    let result = MathSpeech {
                        conversion: converted,
                        text,
                        options,
                    };
                    result.to_json(limits.output_bytes() as usize)?;
                    Ok(Output::Speech(result))
                } else {
                    converted.to_json(limits.output_bytes() as usize)?;
                    Ok(Output::Mathml(converted))
                }
            });
            Ok((operation, languages))
        })
    }
    fn start(
        rules: MathRules,
        limits: MathLimits,
        initialize: impl FnOnce() -> Result<(Operation, Vec<MathLanguage>)> + Send + 'static,
    ) -> Result<Self> {
        let shared = Arc::new(Shared {
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
        });
        let owner = shared.clone();
        let (ready, opened) = mpsc::sync_channel(1);
        let worker = std::thread::Builder::new()
            .name("podoco-math".into())
            .stack_size(8 * 1024 * 1024)
            .spawn(move || {
                let initialized = catch_unwind(AssertUnwindSafe(initialize))
                    .unwrap_or_else(|_| Err(worker_error()));
                let (mut operation, languages) = match initialized {
                    Ok(value) => value,
                    Err(e) => {
                        let _ = ready.send(Err(e));
                        return;
                    }
                };
                if ready.send(Ok(languages)).is_err() {
                    return;
                }
                loop {
                    let request = {
                        let mut state = owner.state.lock().unwrap_or_else(|p| p.into_inner());
                        while state.requests.is_empty() && !state.closed {
                            state = owner.changed.wait(state).unwrap_or_else(|p| p.into_inner());
                        }
                        if state.closed {
                            break;
                        }
                        state.requests.pop_front().expect("nonempty request queue")
                    };
                    let result = catch_unwind(AssertUnwindSafe(|| {
                        operation(request.input, request.speech)
                    }))
                    .unwrap_or_else(|_| Err(worker_error()));
                    match result {
                        Err(error) if error.code == ErrorCode::WorkerFailed => {
                            let pending = {
                                let mut state =
                                    owner.state.lock().unwrap_or_else(|p| p.into_inner());
                                state.closed = true;
                                state.failure = Some(error.clone());
                                std::mem::take(&mut state.requests)
                            };
                            let _ = request.reply.send(Err(error.clone()));
                            for request in pending {
                                let _ = request.reply.send(Err(error.clone()));
                            }
                            break;
                        }
                        result => {
                            let _ = request.reply.send(result);
                        }
                    }
                }
            })
            .map_err(|e| Error::new(ErrorCode::WorkerFailed, e.to_string()))?;
        match opened.recv().unwrap_or_else(|_| Err(worker_error())) {
            Ok(languages) => Ok(Self {
                shared,
                worker: Mutex::new(Some(worker)),
                limits,
                rules,
                languages,
            }),
            Err(error) => {
                let _ = worker.join();
                Err(error)
            }
        }
    }
    /// Available base language/style pairs from the pinned assets.
    pub fn languages(&self) -> &[MathLanguage] {
        &self.languages
    }
    /// Verified assets used for provenance and cache identities.
    pub fn rules(&self) -> &MathRules {
        &self.rules
    }
    /// Effective resource limits.
    pub fn limits(&self) -> MathLimits {
        self.limits
    }
    /// Convert on the processor worker, preserving explicit syntax/limit errors.
    pub fn to_mathml(&self, input: MathInput) -> Result<MathConversion> {
        match self.request(input, None)? {
            Output::Mathml(v) => Ok(v),
            _ => Err(worker_error()),
        }
    }
    /// Generate plain text with one complete explicit preference snapshot.
    pub fn to_speech(&self, input: MathInput, options: MathSpeechOptions) -> Result<MathSpeech> {
        options.validate()?;
        match self.request(input, Some(options))? {
            Output::Speech(v) => Ok(v),
            _ => Err(worker_error()),
        }
    }
    fn request(&self, input: MathInput, speech: Option<MathSpeechOptions>) -> Result<Output> {
        convert::source(&input, self.limits)?;
        let (reply, answer) = mpsc::sync_channel(1);
        {
            let mut state = self.shared.state.lock().unwrap_or_else(|p| p.into_inner());
            if state.closed {
                return Err(state
                    .failure
                    .clone()
                    .unwrap_or_else(|| Error::input("math processor is closed")));
            }
            if state.requests.len() >= self.limits.queued_requests() as usize {
                return Err(types::limit("math request queue is full"));
            }
            state.requests.push_back(Request {
                input,
                speech,
                reply,
            });
            self.shared.changed.notify_one();
        }
        answer.recv().unwrap_or_else(|_| Err(worker_error()))
    }
    /// Cancel queued requests and drain the active conversion. Idempotent;
    /// other math processors, analyzers and TTS sessions remain independent.
    pub fn close(&self) -> Result<()> {
        let pending = {
            let mut state = self.shared.state.lock().unwrap_or_else(|p| p.into_inner());
            state.closed = true;
            self.shared.changed.notify_all();
            std::mem::take(&mut state.requests)
        };
        for request in pending {
            let _ = request.reply.send(Err(Error::new(
                ErrorCode::Cancelled,
                "math processor closed before conversion",
            )));
        }
        if let Some(worker) = self.worker.lock().unwrap_or_else(|p| p.into_inner()).take() {
            worker.join().map_err(|_| worker_error())?;
        }
        Ok(())
    }
}
impl Drop for MathProcessor {
    fn drop(&mut self) {
        let _ = self.close();
    }
}
fn worker_error() -> Error {
    Error::new(
        ErrorCode::WorkerFailed,
        "math conversion worker stopped unexpectedly",
    )
}

fn mathcat_error(error: libmathcat::errors::Error) -> Error {
    let message = error.to_string();
    if message.starts_with("MathCAT crash!") {
        Error::new(
            ErrorCode::WorkerFailed,
            message.chars().take(2048).collect::<String>(),
        )
    } else {
        conversion(message)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::results::FormulaDisplayKind;
    fn input() -> MathInput {
        MathInput::latex("x", FormulaDisplayKind::Inline)
    }
    fn queued(processor: &MathProcessor) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while processor.shared.state.lock().unwrap().requests.is_empty() {
            assert!(std::time::Instant::now() < deadline, "request never queued");
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
    }
    #[test]
    fn bounded_queue_close_cancels_pending_and_drains_active() {
        let (entered, started) = mpsc::sync_channel(1);
        let (resume, blocked) = mpsc::sync_channel(1);
        let limits = MathLimits::new(1, 1024, 4096, 100, 8).unwrap();
        let processor = Arc::new(
            MathProcessor::start(MathRules::testing(), limits, move || {
                Ok((
                    Box::new(move |_, _| {
                        entered.send(()).unwrap();
                        blocked.recv().unwrap();
                        Err(conversion("active operation drained"))
                    }),
                    vec![],
                ))
            })
            .unwrap(),
        );
        let a = processor.clone();
        let active = std::thread::spawn(move || a.to_mathml(input()));
        started.recv().unwrap();
        let a = processor.clone();
        let pending = std::thread::spawn(move || a.to_mathml(input()));
        queued(&processor);
        assert_eq!(
            processor.to_mathml(input()).unwrap_err().code,
            ErrorCode::LimitExceeded
        );
        let a = processor.clone();
        let (done, finished) = mpsc::channel();
        let closing = std::thread::spawn(move || {
            a.close().unwrap();
            done.send(()).unwrap();
        });
        assert_eq!(
            pending.join().unwrap().unwrap_err().code,
            ErrorCode::Cancelled
        );
        assert!(matches!(
            finished.try_recv(),
            Err(mpsc::TryRecvError::Empty)
        ));
        resume.send(()).unwrap();
        assert_eq!(
            active.join().unwrap().unwrap_err().code,
            ErrorCode::Conversion
        );
        closing.join().unwrap();
        finished.recv().unwrap();
        processor.close().unwrap();
        assert_eq!(
            processor.to_mathml(input()).unwrap_err().code,
            ErrorCode::InvalidInput
        );
    }
    #[test]
    fn panic_fails_active_and_pending_requests_without_stranding_waiters() {
        let (entered, started) = mpsc::sync_channel(1);
        let (resume, blocked) = mpsc::sync_channel(1);
        let processor = Arc::new(
            MathProcessor::start(MathRules::testing(), MathLimits::default(), move || {
                Ok((
                    Box::new(move |_, _| {
                        entered.send(()).unwrap();
                        blocked.recv().unwrap();
                        panic!("controlled converter panic")
                    }),
                    vec![],
                ))
            })
            .unwrap(),
        );
        let a = processor.clone();
        let active = std::thread::spawn(move || a.to_mathml(input()));
        started.recv().unwrap();
        let a = processor.clone();
        let pending = std::thread::spawn(move || a.to_mathml(input()));
        queued(&processor);
        resume.send(()).unwrap();
        assert_eq!(
            active.join().unwrap().unwrap_err().code,
            ErrorCode::WorkerFailed
        );
        assert_eq!(
            pending.join().unwrap().unwrap_err().code,
            ErrorCode::WorkerFailed
        );
        assert_eq!(
            processor.to_mathml(input()).unwrap_err().code,
            ErrorCode::WorkerFailed
        );
        processor.close().unwrap();
    }
}
