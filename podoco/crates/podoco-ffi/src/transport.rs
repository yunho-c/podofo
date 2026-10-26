//! Request/reply rendezvous. Wake callbacks carry scalars only, and execute
//! outside all locks. Actual page/result semantics remain in the Rust analyzer.
use crate::{
    types::*,
    wire::{encode, invalid},
};
use podoco::{
    AnalysisJob, AnalysisUpdate, CancellationHandle, DocumentRef, Error, ErrorCode, PageDescriptor,
    PageInput, PageRequest, PageSource, Result,
};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::Duration;

pub(crate) struct SourceRequest {
    token: u64,
    bytes: Option<Box<[u8]>>,
    response: Option<Result<PageInput>>,
}
struct ResultRequest {
    token: u64,
    bytes: Option<Box<[u8]>>,
    response: Option<Result<()>>,
}
#[derive(Default)]
struct State {
    source: Option<SourceRequest>,
    result: Option<ResultRequest>,
    next_source: u64,
    wake_count: u64,
    abandoned: bool,
}
pub(crate) struct Bridge {
    state: Mutex<State>,
    changed: Condvar,
    wake: PodocoWake,
    token: u64,
}
impl Bridge {
    pub fn new(wake: PodocoWake, token: u64) -> Self {
        Self {
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
            wake,
            token,
        }
    }
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }
    fn notify(&self) {
        if let Some(wake) = self.wake {
            {
                let mut state = self.lock();
                state.wake_count = state
                    .wake_count
                    .checked_add(1)
                    .expect("wake count exhausted");
            }
            // SAFETY: C job-start contract keeps this callback callable until
            // native job drain, including all enqueued scalar notifications.
            unsafe {
                wake(self.token);
            }
        }
    }
    pub fn wake_count(&self) -> u64 {
        self.lock().wake_count
    }
    pub fn abandon(&self) {
        let mut s = self.lock();
        s.abandoned = true;
        self.changed.notify_all();
    }
    pub fn load(&self, r: PageRequest) -> Result<PageInput> {
        let cancel = r.cancellation;
        {
            let mut s = self.lock();
            if s.abandoned {
                return Err(stopped());
            }
            let token = s
                .next_source
                .checked_add(1)
                .ok_or_else(|| invalid("source token exhausted"))?;
            s.next_source = token;
            let bytes = encode(
                &serde_json::json!({"schema_version":0,"token":token,
                "page":r.page,"requirements":r.requirements,"byte_budget":r.byte_budget}),
                PODOCO_MAX_METADATA_BYTES,
            )?;
            s.source = Some(SourceRequest {
                token,
                bytes: Some(bytes),
                response: None,
            });
        }
        self.notify();
        self.wait_source(&cancel)
    }
    fn wait_source(&self, cancel: &CancellationHandle) -> Result<PageInput> {
        let mut s = self.lock();
        let mut cancellation_notified = false;
        loop {
            let cancelling = cancel.is_cancelled();
            if cancelling && !cancellation_notified && !s.abandoned {
                cancellation_notified = true;
                drop(s);
                self.notify();
                s = self.lock();
                continue;
            }
            // Once polled, a foreign renderer owns this reservation. Ordinary
            // cancellation must wait for its completion reply, even if that
            // reply only returns a late image for release. Otherwise a queued
            // document could render while the old one still owns its pixels.
            let foreign_done = s
                .source
                .as_ref()
                .is_none_or(|r| r.bytes.is_some() || r.response.is_some());
            if s.abandoned || (cancelling && foreign_done) {
                let pending = s.source.take();
                drop(s);
                drop(pending); // May release an accepted image; never under lock.
                return Err(stopped());
            }
            if let Some(reply) = s.source.as_mut().and_then(|r| r.response.take()) {
                s.source = None;
                return reply;
            }
            // Core cancellation is an independent control channel. A timed
            // wait observes it even when no source reply/wakeup can arrive.
            s = self
                .changed
                .wait_timeout(s, Duration::from_millis(20))
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
    }
    pub fn source_next(&self) -> Option<Box<[u8]>> {
        self.lock().source.as_mut().and_then(|r| r.bytes.take())
    }
    pub fn source_reply(&self, token: u64, reply: Result<PageInput>) -> Result<()> {
        let mut s = self.lock();
        if s.abandoned {
            return Err(stopped());
        }
        let r = s
            .source
            .as_mut()
            .filter(|r| r.token == token && r.bytes.is_none() && r.response.is_none())
            .ok_or_else(|| invalid("stale, unpolled, or already replied source token"))?;
        r.response = Some(reply);
        self.changed.notify_all();
        Ok(())
    }
    pub fn deliver(&self, u: AnalysisUpdate, max: u64) -> Result<()> {
        let token = u.sequence();
        let bytes = u
            .to_json(max.min(isize::MAX as u64) as usize)?
            .into_boxed_slice();
        {
            let mut s = self.lock();
            if s.abandoned {
                return Err(delivery_abandoned());
            }
            s.result = Some(ResultRequest {
                token,
                bytes: Some(bytes),
                response: None,
            });
        }
        self.notify();
        let mut s = self.lock();
        loop {
            if s.abandoned {
                s.result = None;
                return Err(delivery_abandoned());
            }
            if let Some(reply) = s.result.as_mut().and_then(|r| r.response.take()) {
                s.result = None;
                return reply;
            }
            s = self.changed.wait(s).unwrap_or_else(|p| p.into_inner());
        }
    }
    pub fn result_next(&self) -> Option<Box<[u8]>> {
        self.lock().result.as_mut().and_then(|r| r.bytes.take())
    }
    pub fn result_ack(&self, sequence: u64, result: Result<()>) -> Result<()> {
        let mut s = self.lock();
        if s.abandoned {
            return Err(delivery_abandoned());
        }
        let r = s
            .result
            .as_mut()
            .filter(|r| r.token == sequence && r.bytes.is_none() && r.response.is_none())
            .ok_or_else(|| invalid("stale, unpolled, or already acknowledged result sequence"))?;
        r.response = Some(result);
        self.changed.notify_all();
        Ok(())
    }
}
fn stopped() -> Error {
    Error::new(ErrorCode::Cancelled, "source request withdrawn")
}
fn delivery_abandoned() -> Error {
    Error::new(
        ErrorCode::Delivery,
        "foreign job handle abandoned before delivery acknowledgement",
    )
}
pub(crate) struct ForeignSource {
    pub document: DocumentRef,
    pub pages: Vec<PageDescriptor>,
    pub bridge: Arc<Bridge>,
}
impl PageSource for ForeignSource {
    fn document(&self) -> &DocumentRef {
        &self.document
    }
    fn pages(&self) -> &[PageDescriptor] {
        &self.pages
    }
    fn load_page(&mut self, r: PageRequest) -> Result<PageInput> {
        self.bridge.load(r)
    }
}
pub(crate) struct OwnedJob {
    pub job: AnalysisJob,
    pub bridge: Arc<Bridge>,
}
impl Drop for OwnedJob {
    fn drop(&mut self) {
        // Last-handle release is a leak backstop. It must not wait forever for
        // source/result replies from a client which has discarded the handle.
        self.bridge.abandon();
        let _ = self.job.close();
    }
}
