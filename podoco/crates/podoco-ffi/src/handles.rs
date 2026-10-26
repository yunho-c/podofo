//! Registry IDs reject stale handles without reading foreign memory. Native
//! work and destructor/callback execution always occur outside the registry lock.
use podoco::{Error, ErrorCode, PageImage, Result};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
};

pub(crate) struct OwnedAnalyzer {
    pub analyzer: podoco::Analyzer,
    pub limits: podoco::ResourceLimits,
    pub profile: String,
}
pub(crate) enum Entry {
    Analyzer(OwnedAnalyzer),
    Job(crate::transport::OwnedJob),
    Image(PageImage),
    Buffer(Box<[u8]>),
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    Image,
    Buffer,
    Analyzer,
    Job,
}
impl Entry {
    fn kind(&self) -> Kind {
        match self {
            Self::Analyzer(_) => Kind::Analyzer,
            Self::Job(_) => Kind::Job,
            Self::Image(_) => Kind::Image,
            Self::Buffer(_) => Kind::Buffer,
        }
    }
}
#[derive(Default)]
struct Registry {
    next: u64,
    entries: HashMap<u64, Arc<Entry>>,
}
fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(Registry::default()))
}
fn invalid() -> Error {
    Error::new(
        ErrorCode::InvalidInput,
        "unknown, stale, or wrong-kind handle",
    )
}
pub(crate) fn insert(entry: Entry) -> Result<u64> {
    let id = reserve()?;
    publish(id, entry);
    Ok(id)
}
pub(crate) fn reserve() -> Result<u64> {
    let mut r = registry().lock().unwrap_or_else(|p| p.into_inner());
    let id = r
        .next
        .checked_add(1)
        .filter(|&v| v <= i64::MAX as u64)
        .ok_or_else(|| Error::new(ErrorCode::LimitExceeded, "handle identity space exhausted"))?;
    r.next = id;
    Ok(id)
}
pub(crate) fn publish(id: u64, entry: Entry) {
    registry()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .entries
        .insert(id, Arc::new(entry));
}
pub(crate) fn get(id: u64, kind: Kind) -> Result<Arc<Entry>> {
    let r = registry().lock().unwrap_or_else(|p| p.into_inner());
    r.entries
        .get(&id)
        .filter(|e| e.kind() == kind)
        .cloned()
        .ok_or_else(invalid)
}
pub(crate) fn release(id: u64) -> Result<()> {
    if id == 0 {
        return Ok(());
    }
    let entry = registry()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .entries
        .remove(&id)
        .ok_or_else(invalid)?;
    drop(entry);
    Ok(())
}
pub(crate) fn count() -> u64 {
    registry()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .entries
        .len() as u64
}
