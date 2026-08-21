use crate::*;
use chrono::{DateTime, Datelike, LocalResult, NaiveDate, NaiveTime, TimeZone, Utc, Weekday};

// ---- The `[[schedule]]` config: parse, validate, resolve the next fire -------
//
// THE FAILURE THIS IS DESIGNED AGAINST. The recurring turns this replaces lived in a
// desktop scheduler that stopped firing and was not noticed for a month. Everything
// here follows from that: a job that does not run must leave a record saying so, and
// that record must be one authenticated request away (`GET /jesse/schedule`) rather
// than a file timestamp someone has to think to look at.
//
// THE SECOND DRIVER IS THE WORKING TREE. These jobs all write the same vault, so two
// of them overlapping produces real conflicts. The answer is not "space them out at
// wall-clock times and hope the estimates hold" — estimates rot — it is CHAINING: a
// job declares `after = "<other job>"` and fires when that job's turn has actually
// completed. Only a chain HEAD has a clock time. See [`Trigger`].
//
// This module is PURE: it parses, it validates, and it answers "when does this head
// fire next". It spawns nothing and touches no clock of its own — every entry point
// takes the reference instant as a parameter, which is what makes the DST cases below
// testable at all. The runtime is in [`crate::scheduler`]; the persisted record is in
// [`crate::schedstate`].

/// Default catch-up window for a head (`catch_up_secs`): a fire missed by less than
/// this — the host was asleep, the service was restarting — still runs when the
/// service comes back. Beyond it, the run is SKIPPED and the skip is recorded, because
/// a "morning routine" that starts at 4pm is worse than one that visibly did not run.
pub const DEFAULT_CATCH_UP_SECS: u64 = 3600;

/// The opening of the failure reason a job gets when its `prompt_file` cannot be read.
///
/// SHARED WITH THE FIRE LEDGER, which classifies this failure as `no-prompt` rather than
/// the generic `failed`. Keying that on a const rather than on a copied string literal is
/// the point: the missing-prompt case is the one failure that produces NOTHING anywhere
/// else — no child, no transcript, no output file — so a silent drift between the message
/// and the classifier would make the single most invisible failure invisible again.
pub const PROMPT_READ_FAILED: &str = "could not read prompt_file";

/// Default `mode` for a scheduled turn. Scheduled work ACTS (it writes the vault, files
/// the day, runs the routine), so it takes the acting mode rather than the asking one.
pub const DEFAULT_SCHEDULE_MODE: &str = "tell";

/// How far ahead [`next_fire_ms`] will search for a matching weekday. Eight days covers
/// any `days` filter that names at least one weekday (seven, plus one for a candidate
/// that has already passed today) — and bounds the loop so a pathological input cannot
/// spin.
const DAY_SEARCH_LIMIT: i64 = 8;

/// How far past a NONEXISTENT local time (a spring-forward gap) the resolver probes for
/// the instant the clock jumps to. Gaps are an hour in every zone that has one, but the
/// bound is a whole day so an exotic or historical transition still resolves rather than
/// silently dropping the fire.
const GAP_PROBE_MINUTES: i64 = 24 * 60;

// ---- Weekdays ---------------------------------------------------------------

/// The weekdays a job may fire on — a bitmask over `Weekday::num_days_from_monday`,
/// defaulting to all seven.
///
/// It applies to HEADS AND LINKS ALIKE, which is the point: a link narrower than its
/// head (a Monday-only job hanging off a daily chain) is the common case, and it is
/// evaluated when the chain reaches the link, against the local day the chain is
/// running on.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Days(u8);

impl Default for Days {
    fn default() -> Self {
        Days::ALL
    }
}

impl Days {
    /// Every weekday — the default when `days` is absent.
    pub const ALL: Days = Days(0b0111_1111);

    /// Whether `w` is one of this set's days.
    pub fn contains(self, w: Weekday) -> bool {
        self.0 & (1 << w.num_days_from_monday()) != 0
    }

    /// Whether this is the unrestricted set (used to keep the config echo terse).
    pub fn is_all(self) -> bool {
        self == Days::ALL
    }

    /// The canonical three-letter names in week order, for the observability endpoint.
    pub fn names(self) -> Vec<&'static str> {
        const NAMES: [&str; 7] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
        NAMES
            .iter()
            .enumerate()
            .filter(|(i, _)| self.0 & (1 << i) != 0)
            .map(|(_, n)| *n)
            .collect()
    }

    /// Build a set from configured weekday names. An unrecognized name is an error
    /// naming it (the entry is then disabled individually); an empty list is an error
    /// too, since a job that can never fire is a typo, not an intention.
    pub fn parse(names: &[String]) -> Result<Days, String> {
        let mut bits = 0u8;
        for raw in names {
            let w = parse_weekday(raw)
                .ok_or_else(|| format!("`days` contains an unknown weekday {raw:?}"))?;
            bits |= 1 << w.num_days_from_monday();
        }
        if bits == 0 {
            return Err("`days` is empty — the job could never fire".to_string());
        }
        Ok(Days(bits))
    }
}

/// Parse one weekday name: full or three-letter, any case (`"Mon"`, `"monday"`, `"MON"`).
pub fn parse_weekday(raw: &str) -> Option<Weekday> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "mon" | "monday" => Some(Weekday::Mon),
        "tue" | "tues" | "tuesday" => Some(Weekday::Tue),
        "wed" | "weds" | "wednesday" => Some(Weekday::Wed),
        "thu" | "thur" | "thurs" | "thursday" => Some(Weekday::Thu),
        "fri" | "friday" => Some(Weekday::Fri),
        "sat" | "saturday" => Some(Weekday::Sat),
        "sun" | "sunday" => Some(Weekday::Sun),
        _ => None,
    }
}

/// Parse a `"HH:MM"` local wall-clock time. Deliberately strict: exactly two
/// colon-separated fields, both numeric and in range. A time the operator meant and the
/// bridge misread is a job that fires at the wrong hour every day, so there is no
/// lenient fallback.
pub fn parse_hhmm(raw: &str) -> Result<NaiveTime, String> {
    let bad = || format!("`at` is not a HH:MM local time: {raw:?}");
    let (h, m) = raw.trim().split_once(':').ok_or_else(bad)?;
    let h: u32 = h.parse().map_err(|_| bad())?;
    let m: u32 = m.parse().map_err(|_| bad())?;
    NaiveTime::from_hms_opt(h, m, 0).ok_or_else(bad)
}

// ---- The validated entry ----------------------------------------------------

/// What makes a job's predecessor "good enough" to run this link.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AfterOn {
    /// Default. The link runs only if its predecessor RAN successfully. A predecessor
    /// that failed, was skipped, or was disabled stops the chain, and the rest of that
    /// chain is recorded as skipped naming the job that broke it.
    Success,
    /// The link runs regardless of the predecessor's outcome — for the cleanup/report
    /// step that is most needed exactly when the step before it went wrong.
    Any,
}

impl AfterOn {
    fn parse(raw: &str) -> Result<AfterOn, String> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "success" => Ok(AfterOn::Success),
            "any" => Ok(AfterOn::Any),
            other => Err(format!(
                "`after_on` must be \"success\" or \"any\", got {other:?}"
            )),
        }
    }

    /// The wire/label form, for the observability endpoint.
    pub fn label(self) -> &'static str {
        match self {
            AfterOn::Success => "success",
            AfterOn::Any => "any",
        }
    }
}

/// What starts a job: a wall-clock time (a chain HEAD) or another job's completion (a
/// chain LINK). Exactly one, always — an entry with both or neither is disabled
/// individually, because either way the operator's intent is unknowable.
#[derive(Clone, Debug)]
pub enum Trigger {
    /// A HEAD: fires at this LOCAL wall-clock time, on the days its `days` set allows.
    At(NaiveTime),
    /// A LINK: fires when `job` finishes, subject to `on`. Never scheduled by clock.
    After { job: String, on: AfterOn },
}

/// Where a scheduled turn's prompt text comes from.
#[derive(Clone, Debug)]
pub enum PromptSource {
    /// An inline `prompt = "…"`.
    Inline(String),
    /// A `prompt_file = "…"`, READ AT FIRE TIME and never cached at startup, so editing
    /// a prompt never needs a service restart. Relative paths resolve against the vault
    /// root (the one directory the bridge is guaranteed to know; a launchd service's cwd
    /// is not something to hang a prompt on).
    File(PathBuf),
}

impl PromptSource {
    /// Resolve the prompt text for this fire. A missing or unreadable file is an `Err`
    /// carrying the reason — the run is then recorded as FAILED with that reason, never
    /// a panic and never a silently-empty turn.
    pub fn load(&self, vault: &Path) -> Result<String, String> {
        match self {
            PromptSource::Inline(t) => Ok(t.clone()),
            PromptSource::File(p) => {
                let path = if p.is_absolute() {
                    p.clone()
                } else {
                    vault.join(p)
                };
                let text = std::fs::read_to_string(&path)
                    .map_err(|e| format!("{PROMPT_READ_FAILED} {}: {e}", path.display()))?;
                if text.trim().is_empty() {
                    return Err(format!("prompt_file {} is empty", path.display()));
                }
                Ok(text)
            }
        }
    }

    /// The configured path, for the observability endpoint (never the prompt TEXT — the
    /// endpoint reports what a job is, not what it says).
    pub fn label(&self) -> String {
        match self {
            PromptSource::Inline(_) => "inline".to_string(),
            PromptSource::File(p) => p.display().to_string(),
        }
    }
}

/// One validated schedule entry.
#[derive(Clone, Debug)]
pub struct ScheduleJob {
    /// The state key and the handle `after` refers to. Required, unique, stable.
    pub id: String,
    /// `false` disables the job without deleting it. A disabled LINK still breaks a
    /// `after_on = "success"` chain — that is the documented meaning of disabling one.
    pub enabled: bool,
    pub trigger: Trigger,
    pub days: Days,
    pub prompt: PromptSource,
    /// `"ask"` or `"tell"`; defaults to [`DEFAULT_SCHEDULE_MODE`].
    pub mode: String,
    /// Per-job override of the global per-turn run limit, still subject to the existing
    /// clamp (`clamp_timeout_secs`). `None` uses the global one.
    pub timeout_secs: Option<u64>,
    /// Push on completion (default true). Silence is never the default here.
    pub notify: bool,
    /// HEADS ONLY: how late a missed fire may still run. Meaningless on a link (a link
    /// has no clock to be late against), so setting it on one is a config error for that
    /// entry rather than a key that quietly does nothing.
    pub catch_up_secs: u64,
}

impl ScheduleJob {
    /// Whether this entry is a chain head (has a clock time).
    pub fn is_head(&self) -> bool {
        matches!(self.trigger, Trigger::At(_))
    }

    /// The job this one hangs off, or `None` for a head.
    pub fn after(&self) -> Option<&str> {
        match &self.trigger {
            Trigger::After { job, .. } => Some(job.as_str()),
            Trigger::At(_) => None,
        }
    }

    /// This link's predecessor rule (`Success` for a head, which never consults it).
    pub fn after_on(&self) -> AfterOn {
        match &self.trigger {
            Trigger::After { on, .. } => *on,
            Trigger::At(_) => AfterOn::Success,
        }
    }

    /// The head's configured local time as `"HH:MM"`, or `None` for a link.
    pub fn at_label(&self) -> Option<String> {
        match &self.trigger {
            Trigger::At(t) => Some(t.format("%H:%M").to_string()),
            Trigger::After { .. } => None,
        }
    }

    /// The next instant this HEAD fires strictly after `after_ms`, in unix millis.
    /// `None` for a link (links are never scheduled by clock).
    pub fn next_fire_ms<Tz: TimeZone>(&self, tz: &Tz, after_ms: u64) -> Option<u64> {
        match &self.trigger {
            Trigger::At(at) => next_fire_ms(tz, *at, self.days, after_ms),
            Trigger::After { .. } => None,
        }
    }
}

/// An entry that failed validation and was DISABLED INDIVIDUALLY: the rest of the
/// schedule still runs, and this is reported at startup and on the endpoint so it is
/// visible rather than merely absent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InvalidEntry {
    /// The offending entry's `id`, or a positional placeholder when it had none.
    pub id: String,
    pub reason: String,
}

/// The whole validated schedule.
#[derive(Clone, Debug, Default)]
pub struct Schedule {
    /// Entries that validated, in config order.
    pub jobs: Vec<ScheduleJob>,
    /// Entries disabled individually, with the reason.
    pub invalid: Vec<InvalidEntry>,
    /// STARTUP ERRORS: a duplicate `id`, or a cycle in the `after` graph. Both mean the
    /// operator's intent is unknowable — which job is `"nightly"`? which link runs first?
    /// — so unlike everything else here they refuse the boot rather than degrading. Main
    /// prints these and exits; see `Schedule::is_fatal`.
    pub fatal: Vec<String>,
}

impl Schedule {
    /// Whether this schedule must refuse the boot.
    pub fn is_fatal(&self) -> bool {
        !self.fatal.is_empty()
    }

    /// A validated job by id.
    pub fn get(&self, id: &str) -> Option<&ScheduleJob> {
        self.jobs.iter().find(|j| j.id == id)
    }

    /// Every chain HEAD, in config order.
    pub fn heads(&self) -> impl Iterator<Item = &ScheduleJob> {
        self.jobs.iter().filter(|j| j.is_head())
    }

    /// The ids of `head` and everything chained behind it, in EXECUTION ORDER:
    /// depth-first in config order, so a predecessor always precedes everything that
    /// hangs off it. `after` gives each node at most one predecessor, so this is a
    /// forest walk and cannot revisit a node (cycles are refused at startup).
    ///
    /// Two links may share one predecessor. They still run strictly one after the other
    /// — nothing here runs anything concurrently — in config order.
    pub fn chain(&self, head: &str) -> Vec<String> {
        let mut order = Vec::new();
        let mut stack = vec![head.to_string()];
        while let Some(id) = stack.pop() {
            if order.iter().any(|o: &String| o == &id) {
                continue;
            }
            let children: Vec<String> = self
                .jobs
                .iter()
                .filter(|j| j.after() == Some(id.as_str()))
                .map(|j| j.id.clone())
                .collect();
            order.push(id);
            // Reversed so the DFS pops children in config order.
            for c in children.into_iter().rev() {
                stack.push(c);
            }
        }
        order
    }
}

// ---- The TOML shape ---------------------------------------------------------

/// One `[[schedule]]` entry exactly as it appears in the config file.
///
/// Every field is `Option` so that a partial or mistyped entry reaches the VALIDATOR
/// (which disables that one entry and names the problem) instead of failing the parse of
/// the whole overlay file — which would silently take the persona and the model registry
/// down with it.
///
/// `extra` catches every key that is not one of the above. A misspelled key that quietly
/// does nothing is exactly the class of failure this feature exists to end, so an
/// unrecognized key disables the entry and names itself.
#[derive(Deserialize, Default, Clone, Debug)]
pub struct ScheduleToml {
    pub id: Option<String>,
    pub enabled: Option<bool>,
    pub at: Option<String>,
    pub after: Option<String>,
    pub after_on: Option<String>,
    pub days: Option<Vec<String>>,
    pub prompt: Option<String>,
    pub prompt_file: Option<String>,
    pub mode: Option<String>,
    pub timeout_secs: Option<u64>,
    pub notify: Option<bool>,
    pub catch_up_secs: Option<u64>,
    #[serde(flatten)]
    pub extra: HashMap<String, toml::Value>,
}

/// Validate one raw entry into a [`ScheduleJob`], or the reason it is disabled.
///
/// Everything checkable without looking at the other entries happens here; the
/// cross-entry checks (unknown `after` target, duplicate ids, cycles) are in
/// [`validate_schedule`].
fn validate_entry(t: &ScheduleToml) -> Result<ScheduleJob, String> {
    if let Some(key) = t.extra.keys().min() {
        return Err(format!("unknown key `{key}`"));
    }
    let id =
        t.id.as_deref()
            .map(str::trim)
            .unwrap_or_default()
            .to_string();
    if id.is_empty() {
        return Err("missing `id`".to_string());
    }

    let trigger = match (t.at.as_deref(), t.after.as_deref()) {
        (Some(at), None) => Trigger::At(parse_hhmm(at)?),
        (None, Some(after)) => {
            let job = after.trim().to_string();
            if job.is_empty() {
                return Err("`after` is empty".to_string());
            }
            if job == id {
                return Err("`after` names the entry itself".to_string());
            }
            let on = match t.after_on.as_deref() {
                Some(raw) => AfterOn::parse(raw)?,
                None => AfterOn::Success,
            };
            Trigger::After { job, on }
        }
        (Some(_), Some(_)) => {
            return Err("has both `at` and `after` — exactly one is required".to_string())
        }
        (None, None) => {
            return Err("has neither `at` nor `after` — exactly one is required".to_string())
        }
    };
    // `after_on` on a head is as meaningless as `catch_up_secs` on a link, and is
    // rejected for the same reason: a key that silently does nothing is a lie.
    if t.after.is_none() && t.after_on.is_some() {
        return Err("`after_on` is set on a chain head (it has no predecessor)".to_string());
    }
    let is_head = matches!(trigger, Trigger::At(_));
    if !is_head && t.catch_up_secs.is_some() {
        return Err(
            "`catch_up_secs` is set on a chain link — it applies to heads only".to_string(),
        );
    }

    let prompt = match (t.prompt.as_deref(), t.prompt_file.as_deref()) {
        (Some(p), None) => {
            if p.trim().is_empty() {
                return Err("`prompt` is empty".to_string());
            }
            PromptSource::Inline(p.to_string())
        }
        (None, Some(f)) => {
            if f.trim().is_empty() {
                return Err("`prompt_file` is empty".to_string());
            }
            PromptSource::File(PathBuf::from(f.trim()))
        }
        (Some(_), Some(_)) => {
            return Err("has both `prompt` and `prompt_file` — exactly one is required".to_string())
        }
        (None, None) => {
            return Err(
                "has neither `prompt` nor `prompt_file` — exactly one is required".to_string(),
            )
        }
    };

    let days = match &t.days {
        Some(names) => Days::parse(names)?,
        None => Days::ALL,
    };

    let mode = match t.mode.as_deref().map(str::trim) {
        None | Some("") => DEFAULT_SCHEDULE_MODE.to_string(),
        Some(m) => {
            let m = m.to_ascii_lowercase();
            if m != "ask" && m != "tell" {
                return Err(format!("`mode` must be \"ask\" or \"tell\", got {m:?}"));
            }
            m
        }
    };

    Ok(ScheduleJob {
        id,
        enabled: t.enabled.unwrap_or(true),
        trigger,
        days,
        prompt,
        mode,
        timeout_secs: t.timeout_secs,
        notify: t.notify.unwrap_or(true),
        catch_up_secs: t.catch_up_secs.unwrap_or(DEFAULT_CATCH_UP_SECS),
    })
}

/// Validate a whole `[[schedule]]` array.
///
/// THE SPLIT BETWEEN "DISABLED" AND "FATAL" IS DELIBERATE. A scheduler misconfiguration
/// must not take the service down, so a bad entry is disabled individually and its
/// neighbours still run. The two exceptions are a duplicate `id` and a cycle in the
/// `after` graph: both mean the config no longer names one unambiguous thing, so
/// continuing would mean GUESSING which job the operator meant. Those refuse the boot.
pub fn validate_schedule(raw: &[ScheduleToml]) -> Schedule {
    let mut out = Schedule::default();

    // Pass 1: per-entry validation.
    for (i, t) in raw.iter().enumerate() {
        match validate_entry(t) {
            Ok(job) => out.jobs.push(job),
            Err(reason) => out.invalid.push(InvalidEntry {
                id: t
                    .id
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .unwrap_or_else(|| format!("[[schedule]] #{}", i + 1)),
                reason,
            }),
        }
    }

    // FATAL: duplicate ids. Reported before anything else, because every later message
    // (and the whole persisted state file) is keyed on the id being unique.
    let mut seen: HashMap<&str, usize> = HashMap::new();
    let mut dup_reported: Vec<&str> = Vec::new();
    for job in &out.jobs {
        let n = seen.entry(job.id.as_str()).or_insert(0);
        *n += 1;
        if *n == 2 && !dup_reported.contains(&job.id.as_str()) {
            dup_reported.push(job.id.as_str());
        }
    }
    for id in &dup_reported {
        out.fatal.push(format!(
            "duplicate [[schedule]] id {id:?} — ids are the state key and the handle \
             `after` uses, so two entries sharing one make the intent unknowable"
        ));
    }

    // Pass 2: an `after` that names nothing valid. The target may be absent entirely or
    // may itself have been disabled above; either way this link can never fire, and
    // saying so by name beats leaving it quietly inert.
    let valid_ids: Vec<String> = out.jobs.iter().map(|j| j.id.clone()).collect();
    let mut orphaned = Vec::new();
    out.jobs.retain(|j| match j.after() {
        Some(target) if !valid_ids.iter().any(|v| v == target) => {
            orphaned.push(InvalidEntry {
                id: j.id.clone(),
                reason: format!("`after` names {target:?}, which is not a valid schedule entry"),
            });
            false
        }
        _ => true,
    });
    out.invalid.extend(orphaned);

    // FATAL: a cycle in the `after` graph. Each node has at most one predecessor, so a
    // cycle is found by walking parents until we either reach a head or come back to a
    // node already on this walk.
    for cycle in find_cycles(&out.jobs) {
        out.fatal.push(format!(
            "cycle in the [[schedule]] `after` graph: {} — a chain must start at a head \
             with an `at`",
            cycle.join(" -> ")
        ));
    }

    out
}

/// Every distinct cycle in the `after` graph, each rendered as the node ids in walk
/// order with the entry point repeated at the end (`a -> b -> c -> a`). Each cycle is
/// reported once, no matter how many of its members (or tails hanging off it) reach it.
fn find_cycles(jobs: &[ScheduleJob]) -> Vec<Vec<String>> {
    let parent: HashMap<&str, &str> = jobs
        .iter()
        .filter_map(|j| j.after().map(|a| (j.id.as_str(), a)))
        .collect();
    let mut cycles: Vec<Vec<String>> = Vec::new();
    let mut members_seen: Vec<String> = Vec::new();
    for job in jobs {
        if members_seen.contains(&job.id) {
            continue;
        }
        let mut walk: Vec<&str> = vec![job.id.as_str()];
        let mut cur = job.id.as_str();
        while let Some(next) = parent.get(cur) {
            if let Some(pos) = walk.iter().position(|w| w == next) {
                // Found one. Canonicalize to the sub-walk that is actually the loop.
                let mut cycle: Vec<String> = walk[pos..].iter().map(|s| s.to_string()).collect();
                for m in &cycle {
                    members_seen.push(m.clone());
                }
                cycle.push(next.to_string());
                cycles.push(cycle);
                break;
            }
            walk.push(next);
            cur = next;
        }
    }
    cycles
}

// ---- Next-fire resolution (the DST-correct half) -----------------------------

/// Resolve one LOCAL wall-clock date+time to an instant, handling both DST edges.
///
///   * NORMAL — one instant. Used as-is.
///   * AMBIGUOUS (fall back: the local time happens twice) — the EARLIER instant, always.
///     Taking one of the two and never the other is what makes "must not run twice" hold:
///     the caller only ever accepts a candidate STRICTLY LATER than the previous fire, so
///     the second occurrence of the same local time is rejected and the search moves to
///     the next day.
///   * NONEXISTENT (spring forward: the local time is skipped) — the instant the clock
///     jumps TO, found by probing forward a minute at a time. A job at 02:30 on a day
///     whose clocks jump 02:00 → 03:00 therefore runs at 03:00 local. It must not be
///     silently skipped: "the clock passed your time while you weren't looking" is
///     exactly the invisible non-run this whole feature exists to prevent.
fn resolve_local<Tz: TimeZone>(tz: &Tz, date: NaiveDate, at: NaiveTime) -> Option<DateTime<Utc>> {
    match tz.from_local_datetime(&date.and_time(at)) {
        LocalResult::Single(dt) => Some(dt.with_timezone(&Utc)),
        LocalResult::Ambiguous(earliest, _latest) => Some(earliest.with_timezone(&Utc)),
        LocalResult::None => {
            let base = date.and_time(at);
            for m in 1..=GAP_PROBE_MINUTES {
                let probe = base + chrono::Duration::minutes(m);
                match tz.from_local_datetime(&probe) {
                    LocalResult::Single(dt) => return Some(dt.with_timezone(&Utc)),
                    LocalResult::Ambiguous(earliest, _) => {
                        return Some(earliest.with_timezone(&Utc))
                    }
                    LocalResult::None => continue,
                }
            }
            None
        }
    }
}

/// The next instant, STRICTLY AFTER `after_ms`, at which a head with this local time and
/// weekday filter fires — in unix millis.
///
/// Generic over the time zone rather than hard-wired to `Local` so the DST behavior is
/// testable against a named zone with known transitions, instead of against whatever
/// zone the machine running `cargo test` happens to be in.
///
/// `None` only if no candidate resolves within [`DAY_SEARCH_LIMIT`] days, which an
/// entry that passed validation cannot produce (its `days` set is non-empty).
pub fn next_fire_ms<Tz: TimeZone>(
    tz: &Tz,
    at: NaiveTime,
    days: Days,
    after_ms: u64,
) -> Option<u64> {
    let after = DateTime::from_timestamp_millis(after_ms as i64)?;
    let start = after.with_timezone(tz).date_naive();
    for offset in 0..DAY_SEARCH_LIMIT {
        let date = start.checked_add_signed(chrono::Duration::days(offset))?;
        if !days.contains(date.weekday()) {
            continue;
        }
        if let Some(fire) = resolve_local(tz, date, at) {
            if fire > after {
                return Some(fire.timestamp_millis().max(0) as u64);
            }
        }
    }
    None
}

/// The local weekday at `ms`, for the `days` check a chain link makes when the chain
/// reaches it. `None` only for an unrepresentable instant.
pub fn local_weekday<Tz: TimeZone>(tz: &Tz, ms: u64) -> Option<Weekday> {
    let t = DateTime::from_timestamp_millis(ms as i64)?;
    Some(t.with_timezone(tz).date_naive().weekday())
}

/// How far a head's search for missed occurrences will walk. A daily job would need the
/// service to have been gone ~11 years to reach this; it exists only so a clock jumped
/// decades into the past cannot make a tick spin.
const MISSED_SEARCH_LIMIT: u32 = 4000;

/// A head occurrence that is DUE right now.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct DueFire {
    /// The occurrence's scheduled instant (unix millis) — the LATEST one at or before
    /// `now`. This is what gets claimed in the state file.
    pub due_ms: u64,
    /// How late acting on it is. Zero on an on-time tick; large after a sleep or an
    /// outage, which is what `catch_up_secs` is measured against.
    pub lateness_ms: u64,
    /// How many EARLIER occurrences also went by unprocessed (a multi-day outage). They
    /// are collapsed into this one run rather than replayed one per day — replaying a
    /// week of "morning routine" at 9am on Monday is not what anyone wants — but the
    /// count is carried so the record and the log can say it happened.
    pub missed_earlier: u32,
}

/// The occurrence a head must act on at `now_ms`, given the last occurrence it processed
/// (`anchor_ms`), or `None` if its next fire is still in the future.
///
/// Pure, and generic over the zone, so the catch-up and DST behavior can be tested
/// against fixed instants instead of against the wall clock.
pub fn due_occurrence<Tz: TimeZone>(
    tz: &Tz,
    job: &ScheduleJob,
    anchor_ms: u64,
    now_ms: u64,
) -> Option<DueFire> {
    let mut anchor = anchor_ms;
    let mut latest: Option<u64> = None;
    let mut count: u32 = 0;
    while count < MISSED_SEARCH_LIMIT {
        let Some(next) = job.next_fire_ms(tz, anchor) else {
            break;
        };
        if next > now_ms {
            break;
        }
        latest = Some(next);
        anchor = next;
        count += 1;
    }
    latest.map(|due_ms| DueFire {
        due_ms,
        lateness_ms: now_ms.saturating_sub(due_ms),
        missed_earlier: count.saturating_sub(1),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;
    use chrono_tz::America::New_York;

    fn toml_entry(id: &str) -> ScheduleToml {
        ScheduleToml {
            id: Some(id.to_string()),
            prompt: Some("do the thing".to_string()),
            ..Default::default()
        }
    }

    fn head(id: &str, at: &str) -> ScheduleToml {
        ScheduleToml {
            at: Some(at.to_string()),
            ..toml_entry(id)
        }
    }

    fn link(id: &str, after: &str) -> ScheduleToml {
        ScheduleToml {
            after: Some(after.to_string()),
            ..toml_entry(id)
        }
    }

    /// UTC as a `TimeZone`, for the zone-independent resolution tests.
    fn utc() -> FixedOffset {
        FixedOffset::east_opt(0).unwrap()
    }

    fn ms(tz: &chrono_tz::Tz, y: i32, mo: u32, d: u32, h: u32, mi: u32) -> u64 {
        tz.with_ymd_and_hms(y, mo, d, h, mi, 0)
            .single()
            .expect("an unambiguous fixture instant")
            .timestamp_millis() as u64
    }

    fn utc_ms(y: i32, mo: u32, d: u32, h: u32, mi: u32) -> u64 {
        Utc.with_ymd_and_hms(y, mo, d, h, mi, 0)
            .single()
            .unwrap()
            .timestamp_millis() as u64
    }

    // ---- next-fire resolution ------------------------------------------------

    #[test]
    fn next_fire_crosses_the_day_boundary() {
        // 02:30 daily. It is 03:00 on the 5th — today's fire has passed, so the next one
        // is TOMORROW, not a negative interval and not today again.
        let at = parse_hhmm("02:30").unwrap();
        let now = utc_ms(2026, 3, 5, 3, 0);
        let got = next_fire_ms(&utc(), at, Days::ALL, now).unwrap();
        assert_eq!(got, utc_ms(2026, 3, 6, 2, 30));

        // And an hour BEFORE it, the next fire is still today.
        let now = utc_ms(2026, 3, 5, 1, 30);
        let got = next_fire_ms(&utc(), at, Days::ALL, now).unwrap();
        assert_eq!(got, utc_ms(2026, 3, 5, 2, 30));
    }

    #[test]
    fn next_fire_skips_to_the_next_allowed_weekday() {
        // Mondays only. 2026-03-05 is a Thursday, so the next fire is Monday the 9th.
        let at = parse_hhmm("07:00").unwrap();
        let days = Days::parse(&["mon".to_string()]).unwrap();
        let now = utc_ms(2026, 3, 5, 12, 0);
        let got = next_fire_ms(&utc(), at, days, now).unwrap();
        assert_eq!(got, utc_ms(2026, 3, 9, 7, 0));
    }

    #[test]
    fn next_fire_at_the_exact_instant_moves_to_the_following_day() {
        // Strictly-after, so a resolution performed at the exact fire instant returns
        // the NEXT one. This is what stops a job firing twice in one tick window.
        let at = parse_hhmm("06:15").unwrap();
        let now = utc_ms(2026, 3, 5, 6, 15);
        let got = next_fire_ms(&utc(), at, Days::ALL, now).unwrap();
        assert_eq!(got, utc_ms(2026, 3, 6, 6, 15));
    }

    #[test]
    fn dst_spring_forward_does_not_silently_skip_the_job() {
        // 2026-03-08, America/New_York: clocks jump 02:00 EST -> 03:00 EDT. A job at
        // 02:30 has no instant that day. It must still run — at the moment the clock
        // passes it, 03:00 local.
        let at = parse_hhmm("02:30").unwrap();
        let evening_before = ms(&New_York, 2026, 3, 7, 20, 0);
        let got = next_fire_ms(&New_York, at, Days::ALL, evening_before).unwrap();
        assert_eq!(
            got,
            ms(&New_York, 2026, 3, 8, 3, 0),
            "a nonexistent local time fires when the clock jumps past it"
        );

        // The day after the transition it is an ordinary 02:30 again.
        let got = next_fire_ms(&New_York, at, Days::ALL, got).unwrap();
        assert_eq!(got, ms(&New_York, 2026, 3, 9, 2, 30));
    }

    #[test]
    fn dst_fall_back_does_not_run_the_job_twice() {
        // 2026-11-01, America/New_York: clocks fall 02:00 EDT -> 01:00 EST, so 01:30
        // happens TWICE. The job must fire once — on the first (EDT) occurrence — and
        // the next resolution must be the following day, not the second occurrence.
        let at = parse_hhmm("01:30").unwrap();
        let evening_before = ms(&New_York, 2026, 10, 31, 20, 0);
        let first = next_fire_ms(&New_York, at, Days::ALL, evening_before).unwrap();

        let ambiguous = New_York.with_ymd_and_hms(2026, 11, 1, 1, 30, 0);
        let (edt, est) = match ambiguous {
            LocalResult::Ambiguous(a, b) => {
                (a.timestamp_millis() as u64, b.timestamp_millis() as u64)
            }
            _ => panic!("2026-11-01 01:30 America/New_York is the ambiguous hour"),
        };
        assert_eq!(first, edt, "the EARLIER of the two occurrences fires");

        let next = next_fire_ms(&New_York, at, Days::ALL, first).unwrap();
        assert_ne!(next, est, "the repeated hour must not fire a second time");
        assert_eq!(next, ms(&New_York, 2026, 11, 2, 1, 30));
    }

    #[test]
    fn dst_transition_days_still_fire_ordinary_times_once() {
        // The transitions must not disturb a job scheduled outside the affected hour.
        let at = parse_hhmm("09:00").unwrap();
        let spring = next_fire_ms(&New_York, at, Days::ALL, ms(&New_York, 2026, 3, 7, 20, 0));
        assert_eq!(spring, Some(ms(&New_York, 2026, 3, 8, 9, 0)));
        let fall = next_fire_ms(&New_York, at, Days::ALL, ms(&New_York, 2026, 10, 31, 20, 0));
        assert_eq!(fall, Some(ms(&New_York, 2026, 11, 1, 9, 0)));
    }

    // ---- parsing -------------------------------------------------------------

    #[test]
    fn hhmm_parses_and_rejects() {
        assert_eq!(
            parse_hhmm("00:00"),
            Ok(NaiveTime::from_hms_opt(0, 0, 0).unwrap())
        );
        assert_eq!(
            parse_hhmm(" 23:59 "),
            Ok(NaiveTime::from_hms_opt(23, 59, 0).unwrap())
        );
        for bad in ["24:00", "12:60", "12", "12:00:00", "noon", "", "-1:00"] {
            assert!(parse_hhmm(bad).is_err(), "{bad:?} must not parse");
        }
    }

    #[test]
    fn weekday_names_round_trip() {
        let days = Days::parse(&["Sun".into(), "monday".into(), "WED".into()]).unwrap();
        assert_eq!(days.names(), vec!["mon", "wed", "sun"]);
        assert!(days.contains(Weekday::Mon));
        assert!(!days.contains(Weekday::Tue));
        assert!(Days::parse(&["funday".into()]).is_err());
        assert!(Days::parse(&[]).is_err(), "an empty days list is a typo");
    }

    // ---- validation ----------------------------------------------------------

    #[test]
    fn a_head_and_a_link_validate() {
        let s = validate_schedule(&[head("nightly", "02:30"), link("tidy", "nightly")]);
        assert!(s.fatal.is_empty() && s.invalid.is_empty(), "{s:?}");
        assert_eq!(s.jobs.len(), 2);
        assert!(s.jobs[0].is_head());
        assert_eq!(s.jobs[1].after(), Some("nightly"));
        assert_eq!(s.jobs[1].after_on(), AfterOn::Success);
        // Defaults.
        assert!(s.jobs[0].enabled && s.jobs[0].notify);
        assert_eq!(s.jobs[0].mode, "tell");
        assert_eq!(s.jobs[0].catch_up_secs, DEFAULT_CATCH_UP_SECS);
        assert!(s.jobs[0].days.is_all());
    }

    #[test]
    fn every_per_entry_error_disables_only_that_entry() {
        let cases: Vec<(ScheduleToml, &str)> = vec![
            (
                ScheduleToml {
                    at: Some("02:30".into()),
                    after: Some("other".into()),
                    ..toml_entry("both")
                },
                "both `at` and `after`",
            ),
            (toml_entry("neither"), "neither `at` nor `after`"),
            (
                ScheduleToml {
                    catch_up_secs: Some(60),
                    ..link("link-catchup", "good")
                },
                "`catch_up_secs` is set on a chain link",
            ),
            (head("bad-time", "25:00"), "`at` is not a HH:MM"),
            (
                ScheduleToml {
                    days: Some(vec!["funday".into()]),
                    ..head("bad-day", "02:30")
                },
                "unknown weekday",
            ),
            (
                ScheduleToml {
                    after_on: Some("maybe".into()),
                    ..link("bad-after-on", "good")
                },
                "`after_on` must be",
            ),
            (
                ScheduleToml {
                    prompt_file: Some("p.md".into()),
                    ..head("both-prompts", "02:30")
                },
                "both `prompt` and `prompt_file`",
            ),
            (
                ScheduleToml {
                    prompt: None,
                    ..head("no-prompt", "02:30")
                },
                "neither `prompt` nor `prompt_file`",
            ),
            (
                ScheduleToml {
                    mode: Some("shout".into()),
                    ..head("bad-mode", "02:30")
                },
                "`mode` must be",
            ),
            (
                ScheduleToml {
                    id: None,
                    ..head("x", "02:30")
                },
                "missing `id`",
            ),
            (
                link("unknown-target", "nope"),
                "is not a valid schedule entry",
            ),
        ];

        for (entry, want) in cases {
            let id = entry.id.clone();
            // A known-good neighbour on either side of the offender.
            let s = validate_schedule(&[head("good", "01:00"), entry, link("tail", "good")]);
            assert!(
                s.fatal.is_empty(),
                "a bad entry must never be fatal: {:?}",
                s.fatal
            );
            assert_eq!(
                s.invalid.len(),
                1,
                "exactly the offending entry is disabled ({id:?}): {:?}",
                s.invalid
            );
            assert!(
                s.invalid[0].reason.contains(want),
                "reason {:?} should mention {want:?}",
                s.invalid[0].reason
            );
            // THE NEIGHBOURS STILL RUN.
            assert!(s.get("good").is_some() && s.get("tail").is_some());
            assert_eq!(
                s.chain("good"),
                vec!["good".to_string(), "tail".to_string()]
            );
        }
    }

    #[test]
    fn an_unknown_key_disables_the_entry_by_name() {
        let mut e = head("typo", "02:30");
        e.extra
            .insert("catchup_secs".to_string(), toml::Value::Integer(60));
        let s = validate_schedule(&[e, head("good", "01:00")]);
        assert!(s.fatal.is_empty());
        assert_eq!(s.invalid.len(), 1);
        assert!(s.invalid[0].reason.contains("catchup_secs"));
        assert!(s.get("good").is_some());
    }

    #[test]
    fn a_disabled_entry_is_kept_in_the_graph() {
        // `enabled = false` is not a validation error: the entry stays in the schedule
        // (so a `after_on = "success"` link off it correctly sees a broken predecessor)
        // and simply never fires.
        let s = validate_schedule(&[
            ScheduleToml {
                enabled: Some(false),
                ..head("off", "02:30")
            },
            link("tail", "off"),
        ]);
        assert!(s.fatal.is_empty() && s.invalid.is_empty());
        assert!(!s.get("off").unwrap().enabled);
        assert_eq!(s.chain("off"), vec!["off".to_string(), "tail".to_string()]);
    }

    #[test]
    fn a_duplicate_id_is_a_startup_error_naming_it() {
        let s = validate_schedule(&[head("nightly", "02:30"), head("nightly", "03:30")]);
        assert!(s.is_fatal());
        assert!(
            s.fatal.iter().any(|f| f.contains("nightly")),
            "{:?}",
            s.fatal
        );
    }

    #[test]
    fn a_cycle_is_a_startup_error_printing_the_cycle() {
        let s = validate_schedule(&[link("a", "c"), link("b", "a"), link("c", "b")]);
        assert!(s.is_fatal());
        let msg = s.fatal.join("\n");
        assert!(msg.contains("cycle"), "{msg}");
        for id in ["a", "b", "c"] {
            assert!(msg.contains(id), "the cycle must name {id}: {msg}");
        }
        // Reported ONCE, not once per member.
        assert_eq!(s.fatal.len(), 1, "{:?}", s.fatal);
    }

    #[test]
    fn a_two_node_cycle_is_caught() {
        let s = validate_schedule(&[link("a", "b"), link("b", "a")]);
        assert!(s.is_fatal());
        assert_eq!(s.fatal.len(), 1);
    }

    #[test]
    fn chain_order_is_depth_first_in_config_order() {
        // head -> (one, two); one -> deep. Config order decides siblings.
        let s = validate_schedule(&[
            head("head", "02:30"),
            link("one", "head"),
            link("two", "head"),
            link("deep", "one"),
        ]);
        assert!(s.fatal.is_empty() && s.invalid.is_empty());
        assert_eq!(
            s.chain("head"),
            vec![
                "head".to_string(),
                "one".to_string(),
                "deep".to_string(),
                "two".to_string()
            ]
        );
    }

    // ---- the catch-up window -------------------------------------------------

    fn due_head(id: &str, at: &str, catch_up_secs: u64) -> ScheduleJob {
        let s = validate_schedule(&[ScheduleToml {
            catch_up_secs: Some(catch_up_secs),
            ..head(id, at)
        }]);
        assert!(s.fatal.is_empty() && s.invalid.is_empty(), "{s:?}");
        s.jobs.into_iter().next().unwrap()
    }

    #[test]
    fn nothing_is_due_before_the_time_comes() {
        let job = due_head("nightly", "02:30", 3600);
        let anchor = utc_ms(2026, 3, 4, 2, 30);
        // 01:00 the following day: the 02:30 fire has not happened yet.
        assert_eq!(
            due_occurrence(&utc(), &job, anchor, utc_ms(2026, 3, 5, 1, 0)),
            None
        );
    }

    #[test]
    fn a_fire_inside_the_catch_up_window_is_due_and_late() {
        let job = due_head("nightly", "02:30", 3600);
        let anchor = utc_ms(2026, 3, 4, 2, 30);
        // The host woke at 03:00 — 30 minutes late, inside the 1h window.
        let d = due_occurrence(&utc(), &job, anchor, utc_ms(2026, 3, 5, 3, 0)).unwrap();
        assert_eq!(d.due_ms, utc_ms(2026, 3, 5, 2, 30));
        assert_eq!(d.lateness_ms, 30 * 60 * 1000);
        assert_eq!(d.missed_earlier, 0);
        assert!(
            d.lateness_ms <= job.catch_up_secs * 1000,
            "30m late is inside a 1h catch-up window"
        );
    }

    #[test]
    fn a_fire_past_the_catch_up_window_is_still_reported_so_it_can_be_skipped() {
        let job = due_head("nightly", "02:30", 3600);
        let anchor = utc_ms(2026, 3, 4, 2, 30);
        // Woke at 05:00 — 2.5 hours late, well past the window.
        let d = due_occurrence(&utc(), &job, anchor, utc_ms(2026, 3, 5, 5, 0)).unwrap();
        assert_eq!(d.due_ms, utc_ms(2026, 3, 5, 2, 30));
        assert!(
            d.lateness_ms > job.catch_up_secs * 1000,
            "the caller must see it as OUT of the window — and record a skip, never nothing"
        );
    }

    #[test]
    fn a_multi_day_outage_collapses_to_the_latest_occurrence() {
        let job = due_head("nightly", "02:30", 3600);
        // Last processed on the 1st; the service comes back on the 5th at 02:35.
        let anchor = utc_ms(2026, 3, 1, 2, 30);
        let d = due_occurrence(&utc(), &job, anchor, utc_ms(2026, 3, 5, 2, 35)).unwrap();
        assert_eq!(
            d.due_ms,
            utc_ms(2026, 3, 5, 2, 30),
            "the LATEST missed occurrence is the one acted on"
        );
        assert_eq!(d.missed_earlier, 3, "the 2nd, 3rd and 4th went by");
        assert_eq!(d.lateness_ms, 5 * 60 * 1000);
    }

    #[test]
    fn a_weekday_filtered_head_is_only_due_on_its_days() {
        let mut e = head("weekly", "07:00");
        e.days = Some(vec!["mon".into()]);
        let s = validate_schedule(&[e]);
        let job = &s.jobs[0];
        // 2026-03-06 is a Friday: nothing due, even a day after the anchor.
        let anchor = utc_ms(2026, 3, 2, 7, 0); // the previous Monday
        assert_eq!(
            due_occurrence(&utc(), job, anchor, utc_ms(2026, 3, 6, 12, 0)),
            None
        );
        // The following Monday it is.
        let d = due_occurrence(&utc(), job, anchor, utc_ms(2026, 3, 9, 7, 30)).unwrap();
        assert_eq!(d.due_ms, utc_ms(2026, 3, 9, 7, 0));
    }

    #[test]
    fn a_claimed_occurrence_is_not_due_again() {
        // This is the anti-double-fire property: once the occurrence is the anchor, the
        // same instant never comes due again, so a restart mid-window cannot replay it.
        let job = due_head("nightly", "02:30", 3600);
        let due = utc_ms(2026, 3, 5, 2, 30);
        assert_eq!(
            due_occurrence(&utc(), &job, due, utc_ms(2026, 3, 5, 2, 31)),
            None
        );
        assert_eq!(
            due_occurrence(&utc(), &job, due, utc_ms(2026, 3, 5, 23, 59)),
            None
        );
    }

    #[test]
    fn prompt_file_is_read_at_load_time_not_cached() {
        let dir = std::env::temp_dir().join(format!("jesse-sched-prompt-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let src = PromptSource::File(PathBuf::from("routine.md"));
        // Missing → a reason, never a panic.
        let err = src.load(&dir).unwrap_err();
        assert!(err.contains("could not read prompt_file"), "{err}");
        // Present → its contents…
        std::fs::write(dir.join("routine.md"), "first text").unwrap();
        assert_eq!(src.load(&dir).unwrap(), "first text");
        // …and an edit is picked up with no restart, because nothing was cached.
        std::fs::write(dir.join("routine.md"), "second text").unwrap();
        assert_eq!(src.load(&dir).unwrap(), "second text");
        // An empty file is a failure with a reason rather than an empty turn.
        std::fs::write(dir.join("routine.md"), "   \n").unwrap();
        assert!(src.load(&dir).unwrap_err().contains("is empty"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_absolute_prompt_file_is_used_as_given() {
        let dir = std::env::temp_dir().join(format!("jesse-sched-abs-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("abs.md");
        std::fs::write(&file, "absolute").unwrap();
        let src = PromptSource::File(file.clone());
        assert_eq!(
            src.load(Path::new("/nonexistent-vault")).unwrap(),
            "absolute"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
