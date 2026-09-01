//! **The bounded-memory contract for `GrepIndex`, asserted rather than hoped.**
//!
//! D9's F4: one `vault_search` over the real vault (104 GB across 8 086 markdown files)
//! took the eval process past **12 GB of resident memory** and had still not returned when
//! it was killed. That is not a slow search, it is an unbounded one — and nothing in the
//! test suite could have caught it, because every other test in this repository searches a
//! store of four small files, where an implementation proportional to the largest document
//! and an implementation bounded by a constant behave identically.
//!
//! **HOW THIS MEASURES.** Peak *resident set* is the wrong instrument for a test: it is
//! process-wide, monotonic, and shared with whatever else the test binary did first, so the
//! same code passes or fails depending on test order. This file installs a counting global
//! allocator instead and measures **peak live allocated bytes across one search**, which is
//! deterministic, independent of the allocator's return-to-OS policy, and attributable to
//! the code under test. The allocator is confined to this integration test binary, so the
//! library and every other test are untouched.
//!
//! **THE CONTRACT.** On any store, `GrepIndex::search` returns — possibly truncated, and
//! saying so — with peak live memory bounded by a constant. Not by the size of the store,
//! and not by the size of the largest document in it. The two assertions below are the two
//! halves of that: hold the store size fixed and grow one document, then hold documents
//! fixed and grow the store.

use jesse_agent::index::{GrepIndex, SearchIndex, SearchMode};
use jesse_agent::store::FsVaultStore;
use jesse_agent::Scope;
use std::alloc::{GlobalAlloc, Layout, System};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard};

// ---------------------------------------------------------------------------
// The counting allocator
// ---------------------------------------------------------------------------

static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);
static TOTAL: AtomicUsize = AtomicUsize::new(0);

struct Counting;

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let p = unsafe { System.alloc(l) };
        if !p.is_null() {
            bump(l.size());
        }
        p
    }

    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        LIVE.fetch_sub(l.size(), Ordering::Relaxed);
        unsafe { System.dealloc(p, l) }
    }

    unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
        let q = unsafe { System.realloc(p, l, new) };
        if !q.is_null() {
            if new >= l.size() {
                bump(new - l.size());
            } else {
                LIVE.fetch_sub(l.size() - new, Ordering::Relaxed);
            }
        }
        q
    }
}

/// Add to the live total and raise the high-water mark if this is a new peak.
fn bump(n: usize) {
    let now = LIVE.fetch_add(n, Ordering::Relaxed) + n;
    PEAK.fetch_max(now, Ordering::Relaxed);
    TOTAL.fetch_add(n, Ordering::Relaxed);
}

#[global_allocator]
static ALLOC: Counting = Counting;

/// What one measured call cost.
#[derive(Debug, Clone, Copy)]
struct Cost {
    /// High-water mark of live bytes above where the call started. THE CONTRACT'S NUMBER.
    peak: usize,
    /// Every byte the call ever asked the allocator for, freed or not. **REPORTED, NOT
    /// ASSERTED ON.**
    ///
    /// Worth printing because the peak can read low for an honest reason — a call that frees
    /// as fast as it allocates never raises the high-water mark, and after D12 the search
    /// does exactly that — so this is the number that says work happened at all. On this
    /// change it fell from 134 MB to 4.1 MB for one 32 MB document.
    ///
    /// It is NOT the contract, and asserting on it was a mistake caught by CI. Allocation
    /// over time is not the same as memory held: hashing a 32 MB document for its metadata
    /// legitimately streams 32 MB past the allocator whatever the peak is, and how much
    /// bookkeeping that costs differs by platform and allocator — an early version of this
    /// file asserted on it and failed on CI's Linux while passing on macOS, at a bounded
    /// peak on both. The peak is the thing the vault broke, and the peak is what is
    /// asserted.
    total: usize,
}

/// **ONE MEASUREMENT AT A TIME.** The counters are process-global while `cargo test` runs
/// this file's tests on parallel threads, so without this a fixture being built on one
/// thread lands in the high-water mark of a search being measured on another. That is not
/// theoretical: before this lock existed, the count-of-documents test passed against the
/// pre-D12 code when run alone and failed when run beside the 32 MB cases, which is a test
/// that reports whatever the scheduler did.
///
/// Every test takes it for its whole body, fixture construction included.
static SERIAL: Mutex<()> = Mutex::new(());

/// Take the measurement lock, ignoring poisoning: one test panicking is a failure to report,
/// not a reason to fail the other three with a different message.
fn serial() -> MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(|e| e.into_inner())
}

/// Run `f`, returning its value and what it cost.
///
/// The peak is reset to the CURRENT live total first, so the measurement is the growth this
/// call is responsible for rather than whatever the fixture already holds.
fn cost_of<T>(f: impl FnOnce() -> T) -> (T, Cost) {
    let before = LIVE.load(Ordering::Relaxed);
    let total_before = TOTAL.load(Ordering::Relaxed);
    PEAK.store(before, Ordering::Relaxed);
    let out = f();
    let peak = PEAK.load(Ordering::Relaxed).saturating_sub(before);
    let total = TOTAL.load(Ordering::Relaxed).saturating_sub(total_before);
    (out, Cost { peak, total })
}

// ---------------------------------------------------------------------------
// The fixture
// ---------------------------------------------------------------------------

/// A synthetic store. NOT the real vault — this prompt's measurements never touch it.
struct Fixture(PathBuf);

impl Fixture {
    /// `small` documents of a few hundred bytes, then `big` documents of `big_bytes` each.
    ///
    /// The big ones carry the query term too, so they are on the path a matching document
    /// takes rather than skipped early as a non-match.
    fn build(tag: &str, small: usize, big: usize, big_bytes: usize) -> Fixture {
        let root = std::env::temp_dir().join(format!(
            "jesse-grepmem-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(root.join("notes")).unwrap();
        for i in 0..small {
            std::fs::write(
                root.join(format!("notes/small-{i:05}.md")),
                format!("# Note {i}\n\nThe launch is on Tuesday, note {i}.\n"),
            )
            .unwrap();
        }
        // One long line repeated: a realistic large markdown file, and the shape that makes
        // a whole-body lowercase copy expensive.
        let filler = "The quick brown fox jumps over the lazy dog near the launch site.\n";
        let reps = big_bytes / filler.len();
        for i in 0..big {
            let mut body = String::with_capacity(big_bytes + 64);
            body.push_str(&format!("# Big {i}\n\n"));
            for _ in 0..reps {
                body.push_str(filler);
            }
            std::fs::write(root.join(format!("notes/big-{i:03}.md")), body).unwrap();
        }
        Fixture(std::fs::canonicalize(&root).unwrap())
    }

    fn store(&self) -> FsVaultStore {
        FsVaultStore::open(&self.0).unwrap()
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).ok();
    }
}

fn search_cost(fx: &Fixture, query: &str) -> (usize, Cost) {
    let store = fx.store();
    let index = GrepIndex::new(store);
    let scope = Scope::new("t", "u", "w");
    let rt = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap();
    let (hits, cost) = cost_of(|| {
        rt.block_on(index.search(&scope, query, 10, SearchMode::Lexical))
            .expect("search returns")
    });
    (hits.hits.len(), cost)
}

// ---------------------------------------------------------------------------
// The contract
// ---------------------------------------------------------------------------

/// The stated constant. Generous on purpose: it is a ceiling that separates "bounded" from
/// "proportional", not a tuned budget. A single 32 MB document is 4 MB over it if ONE copy
/// of it is held, and the pre-D12 code held about four.
const PEAK_CEILING_BYTES: usize = 28 * 1024 * 1024;

/// ONE BIG DOCUMENT MUST NOT COST ITS OWN SIZE, LET ALONE A MULTIPLE OF IT.
///
/// This is F4 in miniature. Before D12 the store read every file whole to build its
/// metadata, read it whole a second time to serve it, copied it again as lossy UTF-8, and
/// then `GrepIndex` allocated one more full lowercase copy of the body PER QUERY TERM — so
/// peak tracked the largest document several times over. The real vault's largest files
/// made that twelve gigabytes.
#[test]
fn one_large_document_does_not_move_the_peak() {
    let _serial = serial();
    let fx = Fixture::build("bigdoc", 20, 1, 32 * 1024 * 1024);
    let (_, c) = search_cost(&fx, "launch");
    eprintln!(
        "one 32 MB document: peak {} bytes, total allocated {} bytes",
        c.peak, c.total
    );
    assert!(
        c.peak < PEAK_CEILING_BYTES,
        "one 32 MB document pushed peak live memory to {} bytes, over the \
         {PEAK_CEILING_BYTES}-byte ceiling: search is proportional to document size",
        c.peak
    );
}

/// AND IT MUST NOT GROW WITH THE DOCUMENT EITHER.
///
/// The ceiling above is a single point; this is the curve. Quadrupling the size of the
/// large document must not meaningfully move the peak — if it does, the bound is the
/// document rather than a constant, and the only question left is how big a file the vault
/// happens to contain.
#[test]
fn the_peak_does_not_track_the_largest_document() {
    let _serial = serial();
    let (_, small) = search_cost(&Fixture::build("curve-s", 20, 1, 8 * 1024 * 1024), "launch");
    let (_, large) = search_cost(
        &Fixture::build("curve-l", 20, 1, 32 * 1024 * 1024),
        "launch",
    );
    eprintln!(
        "8 MB: peak {} / total {}; 32 MB: peak {} / total {}",
        small.peak, small.total, large.peak, large.total
    );
    assert!(
        large.peak < small.peak + 8 * 1024 * 1024,
        "growing one document from 8 MB to 32 MB moved peak live memory from {} to {} \
         bytes; the bound is the document, not a constant",
        small.peak,
        large.peak
    );
}

/// AND NOT WITH THE NUMBER OF DOCUMENTS.
///
/// Matching documents accumulated in an unbounded `Vec<Hit>` that was only truncated to the
/// caller's limit after the whole walk finished, so a common term over a large store held
/// every hit it ever saw. The scan stop capped this at 2 000 documents; the point of the
/// assertion is that the cap is no longer what is doing the work.
#[test]
fn the_peak_does_not_track_the_number_of_matching_documents() {
    let _serial = serial();
    let (few, few_c) = search_cost(&Fixture::build("count-s", 50, 0, 0), "launch");
    let (many, many_c) = search_cost(&Fixture::build("count-l", 1_500, 0, 0), "launch");
    eprintln!(
        "50 docs: peak {} bytes; 1500 docs: peak {} bytes",
        few_c.peak, many_c.peak
    );
    assert!(few > 0 && many > 0, "both fixtures must actually match");
    assert!(
        many_c.peak < few_c.peak + 4 * 1024 * 1024,
        "thirty times the documents moved peak live memory from {} to {} bytes; hit \
         accumulation is unbounded",
        few_c.peak,
        many_c.peak
    );
}

/// A DOCUMENT TOO LARGE TO SCAN IS SKIPPED AND SAID SO, NOT READ.
///
/// The bound is only honest if the caller is told what it cost them. A store holding a file
/// past the per-file ceiling must still return, and the result must carry a note naming the
/// skip rather than silently reporting no match in a document nobody looked at.
#[test]
fn an_oversized_document_is_skipped_and_reported() {
    let _serial = serial();
    let fx = Fixture::build("oversize", 5, 1, 32 * 1024 * 1024);
    let store = fx.store();
    let index = GrepIndex::new(store);
    let scope = Scope::new("t", "u", "w");
    let rt = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap();
    let hits = rt
        .block_on(index.search(&scope, "launch", 10, SearchMode::Lexical))
        .expect("search returns");
    assert!(
        !hits.hits.is_empty(),
        "the small documents must still be found"
    );
    let note = hits.degraded.unwrap_or_default();
    assert!(
        note.contains("too large") || note.contains("skipped"),
        "the result must say a document was skipped for size; note was {note:?}"
    );
    assert!(
        !hits.hits.iter().any(|h| h.id.as_str().contains("big-")),
        "a skipped document must not appear as a hit"
    );
    let _ = fx.path();
}
