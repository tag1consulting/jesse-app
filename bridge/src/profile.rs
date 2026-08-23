use crate::*;

// ---- The away profile --------------------------------------------------------
//
// ONE PIECE OF BRIDGE STATE THE PHONE CAN SET AND THAT EXPIRES BY ITSELF, and the whole
// design follows from that second half. The thing it is for is "I am in the UK for two
// weeks with only my phone": the scheduler's zone moves, part of the job set stops making
// sense, and every prompt needs to say so. The failure mode of a manual switch is
// forgetting to switch back — a profile with no end date is a bridge that stays in the
// wrong zone until someone notices — so `until` is REQUIRED when going away, exactly as it
// is for the schedule's enable override (`EnableOverride`), and for the same reason.
//
// THE BRIDGE DOES NOT KNOW WHAT "AWAY" MEANS. It knows three mechanical consequences and
// nothing else:
//
//   * the zone every date is derived in ([`effective_tz`]);
//   * which `[[schedule]]` members are absent (`profiles = [...]`, see [`crate::schedule`]);
//   * one line in every prompt (`PROFILE: away (Europe/London) until …`).
//
// Everything else — what a working day looks like from a hotel, which routines to soften —
// is vault-side prompt text branching on that line. Teaching the bridge the SEMANTICS of
// being away would mean redeploying a Rust service to change one's mind about a routine.
//
// HOME IS THE ABSENCE OF AN AWAY PERIOD, not a second stored state. There is nothing to
// persist about being home (the zone is the process's, every job is in scope, the prompt
// line is a constant), so the store holds at most one away period and a flag saying whether
// its return has been dealt with.

/// Which profile is in force.
#[derive(serde::Serialize, serde::Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum ProfileName {
    /// The default: the process's zone, every job in scope, `PROFILE: home`.
    Home,
    /// A declared, EXPIRING absence in another zone.
    Away,
}

impl ProfileName {
    /// The wire spelling, and the word the vault-side prompts match on.
    pub fn label(self) -> &'static str {
        match self {
            ProfileName::Home => "home",
            ProfileName::Away => "away",
        }
    }

    /// Parse the wire spelling, case-insensitively. `None` for anything else.
    pub fn parse(raw: &str) -> Option<ProfileName> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "home" => Some(ProfileName::Home),
            "away" => Some(ProfileName::Away),
            _ => None,
        }
    }
}

/// The longest `note` the endpoint accepts. It rides on the clock line of EVERY prompt, so
/// it is a label ("Scotland"), not a paragraph — a long one would spend the model's
/// attention on itself once per turn, every turn, for a fortnight.
pub const MAX_PROFILE_NOTE: usize = 80;

/// One declared away period.
#[derive(serde::Serialize, serde::Deserialize, Clone, PartialEq, Debug)]
pub struct Profile {
    /// Always [`ProfileName::Away`] in a stored record — see the module note on why home
    /// is the absence of one. Kept on the struct because it is what the wire carries, and
    /// because a hand-edited file naming `home` must read back as "nothing is in force"
    /// rather than as a malformed record.
    pub name: ProfileName,
    /// The IANA zone, validated against the tz database before it is stored.
    pub tz: String,
    /// When the period began, unix millis. The `RETURN:` line's "N days away" counts from
    /// this.
    pub since_ms: u64,
    /// When it stops applying, unix millis. `None` means "until it is changed" — the
    /// endpoint never writes that (it requires a future `until`), but a hand-edited file
    /// may, and reading it as "no expiry" is the honest interpretation of the field.
    #[serde(default)]
    pub until_ms: Option<u64>,
    /// A short free-text label, at most [`MAX_PROFILE_NOTE`] characters.
    #[serde(default)]
    pub note: String,
}

impl Profile {
    /// Whether this period is in force at `now_ms`.
    pub fn effective_at(&self, now_ms: u64) -> bool {
        self.name == ProfileName::Away && self.until_ms.map(|u| now_ms < u).unwrap_or(true)
    }

    /// The zone, if it names one the tz database knows.
    pub fn zone(&self) -> Option<SchedulerZone> {
        parse_iana(&self.tz)
    }

    /// How many whole days this period had run by `now_ms`, counted in its OWN zone.
    ///
    /// Counted in local days rather than in elapsed milliseconds because the sentence it
    /// feeds ("first day back after 13 days away") is a claim about calendar days, and
    /// `until - since` divided by 86_400_000 is off by one for any trip that started in
    /// the evening and ended in the morning — which is most of them.
    pub fn days_away(&self, now_ms: u64) -> i64 {
        let Some(zone) = self.zone() else {
            return ((now_ms.saturating_sub(self.since_ms)) / 86_400_000) as i64;
        };
        let day = |ms: u64| {
            chrono::DateTime::from_timestamp_millis(ms as i64)
                .map(|t| t.with_timezone(&zone).date_naive())
        };
        match (day(self.since_ms), day(now_ms)) {
            (Some(a), Some(b)) => (b - a).num_days(),
            _ => 0,
        }
    }
}

/// Resolve an IANA zone name against the bundled tz database.
///
/// The ONE gate every zone string passes, wherever it arrives from — the profile endpoint,
/// a `client_tz` query parameter, a request body, or the stored file. A name the database
/// does not know is `None` and the caller falls back; nothing downstream ever holds a zone
/// string that has not been through here.
pub fn parse_iana(raw: &str) -> Option<SchedulerZone> {
    raw.trim()
        .parse::<chrono_tz::Tz>()
        .ok()
        .map(SchedulerZone::Named)
}

/// The whole persisted file: at most one away period, plus whether its return has been
/// dealt with.
#[derive(serde::Serialize, serde::Deserialize, Clone, Default, PartialEq, Debug)]
pub struct ProfileState {
    /// The away period — live, or ENDED AND KEPT. See [`ProfileStore::go_home`].
    #[serde(default)]
    pub profile: Option<Profile>,
    /// When the `[profile].on_return` chain was fired for the period above, unix millis.
    /// `None` while the return is still owed, which is what makes the fire happen exactly
    /// once across a restart.
    #[serde(default)]
    pub returned_ms: Option<u64>,
}

/// The away-profile store. Cheaply shared behind an `Arc` in `AppState`, and read by the
/// scheduler on every tick.
///
/// Mirrors [`ModelStore`]'s discipline exactly: one small JSON file under the state dir,
/// atomic temp+rename writes at mode 0600, best-effort (a write failure is logged, never
/// fatal), and in-memory only when no state dir is configured. It NEVER holds a secret —
/// a zone name, two instants and a short label.
pub struct ProfileStore {
    state: Mutex<ProfileState>,
    /// Where it is persisted. `None` → in-memory only, so an away profile set on a bridge
    /// with no state dir is lost on restart (the same degradation every other store has).
    path: Option<PathBuf>,
}

impl ProfileStore {
    /// Build the store, loading any period left from a previous run. An unreadable, absent
    /// or corrupt file loads as "home", never an error.
    pub fn new(path: Option<PathBuf>) -> Self {
        let state = path.as_deref().and_then(load_profile).unwrap_or_default();
        ProfileStore {
            state: Mutex::new(state),
            path,
        }
    }

    /// The away period IN FORCE at `now_ms`, or `None` for home.
    ///
    /// Expiry is applied on READ rather than by a sweep: there is no moment at which
    /// something must run for a profile to lapse, so making the reader apply the rule is
    /// what guarantees a bridge that was asleep across the expiry comes back home.
    pub fn current(&self, now_ms: u64) -> Option<Profile> {
        self.state
            .lock_ok()
            .profile
            .clone()
            .filter(|p| p.effective_at(now_ms))
    }

    /// The stored period whether or not it is still in force, for the endpoint's echo —
    /// "it was away until Sunday and Sunday has passed" is a thing someone asks.
    pub fn stored(&self) -> Option<Profile> {
        self.state.lock_ok().profile.clone()
    }

    /// The zone every date is derived in when no client overrides it: the away period's
    /// while one is in force, else the process's.
    pub fn zone(&self, now_ms: u64) -> SchedulerZone {
        self.current(now_ms)
            .and_then(|p| p.zone())
            .unwrap_or(SchedulerZone::Host)
    }

    /// Declare an away period, replacing any previous one and re-owing its return.
    pub fn set_away(&self, profile: Profile) {
        self.write(|s| {
            s.profile = Some(profile);
            s.returned_ms = None;
        });
    }

    /// Come home NOW.
    ///
    /// This ENDS the period rather than erasing the record, and the difference is the
    /// `on_return` fire: the return chain must run exactly once and must survive a restart,
    /// which it cannot do if the only evidence that a trip happened is deleted at the
    /// moment it ends. `current` returns `None` immediately either way, so from every
    /// reader's point of view the store is cleared. Returns the period that was ended.
    pub fn go_home(&self, now_ms: u64) -> Option<Profile> {
        let mut ended = None;
        self.write(|s| {
            if let Some(p) = s.profile.as_mut() {
                if p.effective_at(now_ms) {
                    p.until_ms = Some(now_ms);
                    ended = Some(p.clone());
                }
            }
        });
        ended
    }

    /// The away period whose RETURN has not been dealt with, at `now_ms`.
    ///
    /// `Some` only for a period that has actually lapsed and has never been returned from.
    /// The scheduler consults this on every tick, so a return fire happens whether the
    /// expiry was observed live, arrived through `POST /jesse/profile {"name":"home"}`, or
    /// went by while the host was asleep.
    pub fn return_owed(&self, now_ms: u64) -> Option<Profile> {
        let s = self.state.lock_ok();
        if s.returned_ms.is_some() {
            return None;
        }
        s.profile
            .clone()
            .filter(|p| p.name == ProfileName::Away && !p.effective_at(now_ms))
    }

    /// Record that the return was dealt with, so it is never fired twice.
    pub fn mark_returned(&self, now_ms: u64) {
        self.write(|s| s.returned_ms = Some(now_ms));
    }

    /// When the last return fired, for the endpoint.
    pub fn returned_ms(&self) -> Option<u64> {
        self.state.lock_ok().returned_ms
    }

    /// Mutate and persist under one lock, so two concurrent writes can never leave a file
    /// reflecting neither.
    fn write(&self, f: impl FnOnce(&mut ProfileState)) {
        let snapshot = {
            let mut state = self.state.lock_ok();
            f(&mut state);
            state.clone()
        };
        if let Some(path) = &self.path {
            persist_profile(path, &snapshot);
        }
    }
}

/// THE ONE FUNCTION EVERY DATE IN THE BRIDGE IS DERIVED THROUGH.
///
/// Three sources, in strict precedence:
///
///   1. `client_tz` — the device that is asking. It outranks the profile because it is the
///      more specific claim: the profile says where the owner is *this fortnight*, the
///      phone says what zone it is in *right now*, and when they disagree the phone is
///      standing in the zone the person is standing in.
///   2. the away profile, for a request with no client (every scheduled turn) and for any
///      client that did not say.
///   3. the process zone (`TZ` under launchd — `Europe/Rome` in this deployment), which is
///      what [`SchedulerZone::Host`] resolves to and what every path did before profiles
///      existed. With no profile and no `client_tz` this returns `Host`, so the output is
///      byte-for-byte what it was.
///
/// An UNPARSEABLE `client_tz` falls through to the next source rather than failing the
/// request: a stale app build sending a zone name this tz database does not know must not
/// be unable to tick a checkbox. The caller logs it (see [`log_bad_client_tz`]).
pub fn effective_tz(client_tz: Option<&str>, profile: &ProfileStore, now_ms: u64) -> SchedulerZone {
    if let Some(zone) = client_tz
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .and_then(parse_iana)
    {
        return zone;
    }
    profile.zone(now_ms)
}

/// One stderr line for a `client_tz` that named a zone the tz database does not know.
///
/// Ignoring it silently is what would make the next "why is the stamp an hour out" report
/// unanswerable: the request succeeded, the date is subtly wrong, and nothing anywhere
/// says which of the three sources was used.
pub fn log_bad_client_tz(where_: &str, raw: &str) {
    eprintln!(
        "jesse-bridge: WARNING {where_} sent client_tz={raw:?}, which is not an IANA zone \
         name — falling back to the profile/process zone for this request"
    );
}

/// Load the stored state, tolerating corruption by returning `None` (→ home). Unknown
/// fields are ignored, so a file written by a future bridge loads cleanly.
///
/// A record whose `tz` the tz database does not know is DROPPED with one logged notice
/// rather than kept: a stored zone that cannot be resolved would otherwise silently
/// degrade every date to the host's while the endpoint still reported "away", which is the
/// one state in which the wrong answer looks like the right one.
pub fn load_profile(path: &Path) -> Option<ProfileState> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut state = serde_json::from_str::<ProfileState>(&text).ok()?;
    if let Some(p) = &state.profile {
        if p.name == ProfileName::Away && p.zone().is_none() {
            eprintln!(
                "jesse-bridge: NOTICE {} names the time zone {:?}, which this tz database \
                 does not know. Dropping the away profile; the bridge is home.",
                path.display(),
                p.tz
            );
            state.profile = None;
            state.returned_ms = None;
        }
    }
    Some(state)
}

/// Persist atomically (temp + rename), mode 0600 — the same discipline as
/// [`persist_selection`]. Best-effort: a failure is logged, never fatal.
pub fn persist_profile(path: &Path, state: &ProfileState) {
    let value = json!({ "v": 1, "profile": state.profile, "returned_ms": state.returned_ms });
    let tmp = path.with_extension("json.tmp");
    let write = || -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(value.to_string().as_bytes())?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    };
    if let Err(e) = write() {
        eprintln!("warning: could not persist the away profile: {e}");
        let _ = std::fs::remove_file(&tmp);
    }
}

// ---- The endpoints -----------------------------------------------------------

/// `GET /jesse/profile` — what profile is in force, in what zone, until when.
///
/// Auth-gated with everything else, and deliberately answering even when nothing is set:
/// "home" is an answer, and an endpoint that 404s when the interesting case is absent is
/// one a client has to special-case.
pub async fn jesse_profile(
    State(st): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    Ok(Json(profile_body(&st)))
}

/// `POST /jesse/profile`.
#[derive(Deserialize)]
pub struct ProfileBody {
    /// `"home"` | `"away"`.
    pub name: String,
    /// The IANA zone. REQUIRED for `away`, ignored for `home`.
    #[serde(default)]
    pub tz: Option<String>,
    /// When the period ends, RFC 3339. REQUIRED for `away`, and it must be in the future.
    #[serde(default)]
    pub until: Option<String>,
    /// A short label that rides on every prompt's `PROFILE:` line.
    #[serde(default)]
    pub note: Option<String>,
}

/// `POST /jesse/profile` — declare an away period, or come home.
///
/// `away` REQUIRES both a valid zone and a FUTURE `until`, and neither is a formality. A
/// zone the tz database does not know would leave the bridge reporting "away" while
/// silently deriving every date in the host's zone — the one failure state in which the
/// wrong answer looks like the right one. And an unbounded away profile is a bridge left in
/// the wrong zone until somebody notices: the failure mode of a manual switch is forgetting
/// to switch back, which is why the schedule's enable override expires too.
///
/// Writing the store is only half of it. The scheduler is re-anchored SYNCHRONOUSLY before
/// this returns (see `Scheduler::observe_profile_change`), so the caller's next
/// `GET /jesse/schedule` already shows the new zone's fire times rather than the old
/// zone's for up to one tick.
pub async fn jesse_set_profile(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<ProfileBody>,
) -> Result<Json<Value>, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }
    let now_ms = system_time_to_ms(SystemTime::now());
    let name = ProfileName::parse(&body.name).ok_or((
        StatusCode::BAD_REQUEST,
        format!("`name` must be \"home\" or \"away\", got {:?}", body.name),
    ))?;

    match name {
        ProfileName::Home => {
            if let Some(ended) = st.profile.go_home(now_ms) {
                eprintln!(
                    "jesse-bridge: profile HOME — the away period in {} ended early ({} \
                     day(s) in)",
                    ended.tz,
                    ended.days_away(now_ms)
                );
            }
        }
        ProfileName::Away => {
            let raw_tz = body.tz.as_deref().map(str::trim).unwrap_or_default();
            let zone = parse_iana(raw_tz).ok_or((
                StatusCode::BAD_REQUEST,
                format!(
                    "`tz` must be an IANA time zone name (e.g. \"Europe/London\"), got {raw_tz:?}"
                ),
            ))?;
            let raw_until = body.until.as_deref().map(str::trim).unwrap_or_default();
            let until_ms = chrono::DateTime::parse_from_rfc3339(raw_until)
                .map_err(|e| {
                    (
                        StatusCode::BAD_REQUEST,
                        format!("`until` must be an RFC 3339 instant: {e}"),
                    )
                })?
                .timestamp_millis()
                .max(0) as u64;
            if until_ms <= now_ms {
                return Err((
                    StatusCode::BAD_REQUEST,
                    format!(
                        "`until` is in the past ({raw_until}) — an away profile expires by \
                         itself, so it must end later than it starts"
                    ),
                ));
            }
            let note = body.note.as_deref().map(str::trim).unwrap_or_default();
            if note.chars().count() > MAX_PROFILE_NOTE {
                return Err((
                    StatusCode::BAD_REQUEST,
                    format!(
                        "`note` is {} characters; the limit is {MAX_PROFILE_NOTE} because it \
                         rides on the clock line of every prompt",
                        note.chars().count()
                    ),
                ));
            }
            st.profile.set_away(Profile {
                name: ProfileName::Away,
                tz: zone.iana_name().unwrap_or_else(|| raw_tz.to_string()),
                since_ms: now_ms,
                until_ms: Some(until_ms),
                note: note.to_string(),
            });
            eprintln!("jesse-bridge: profile AWAY tz={raw_tz} until_ms={until_ms} note={note:?}");
        }
    }

    // The re-anchor and the ledger line, on the same path the tick uses — one
    // implementation, so a change made from the phone and one a tick notices can never
    // leave the anchors in different states.
    st.scheduler.clone().observe_profile_change(&st, now_ms);
    Ok(Json(profile_body(&st)))
}

/// The body both profile endpoints answer with, so a client never has to reconcile two
/// views of the same state.
fn profile_body(st: &AppState) -> Value {
    let now_ms = system_time_to_ms(SystemTime::now());
    let stored = st.profile.stored();
    let effective = st.profile.current(now_ms);
    json!({
        // The EFFECTIVE name — `home` whenever nothing is in force, including a period that
        // has expired but whose record is still on disk.
        "name": effective.as_ref().map(|_| "away").unwrap_or("home"),
        // The zone dates are actually derived in right now.
        "tz": effective_tz(None, &st.profile, now_ms)
            .iana_name()
            .unwrap_or_else(|| "UTC".to_string()),
        // The stored period's own fields, live or lapsed, so "it was away until Sunday and
        // Sunday has passed" is answerable from this one request.
        "since_ms": stored.as_ref().map(|p| p.since_ms),
        "until_ms": stored.as_ref().and_then(|p| p.until_ms),
        "note": stored.as_ref().map(|p| p.note.clone()).unwrap_or_default(),
        // Whether that stored period is the one in force — the field that tells the two
        // cases above apart.
        "effective": effective.is_some(),
        // The host's own zone, always, so a reader can see what `away` is a departure FROM.
        "process_tz": SchedulerZone::Host
            .iana_name()
            .unwrap_or_else(|| "UTC".to_string()),
        // When the `[profile].on_return` chain last fired for the stored period, or null
        // while it is still owed.
        "returned_ms": st.profile.returned_ms(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_profile_path() -> PathBuf {
        std::env::temp_dir().join(format!("jesse-profile-{}/profile.json", random_hex()))
    }

    fn away(since_ms: u64, until_ms: u64) -> Profile {
        Profile {
            name: ProfileName::Away,
            tz: "Europe/London".to_string(),
            since_ms,
            until_ms: Some(until_ms),
            note: "Scotland".to_string(),
        }
    }

    #[test]
    fn a_fresh_store_is_home() {
        let store = ProfileStore::new(None);
        assert!(store.current(1_000).is_none());
        assert_eq!(store.zone(1_000), SchedulerZone::Host);
        assert!(store.return_owed(1_000).is_none());
    }

    #[test]
    fn an_away_period_applies_until_it_expires_and_not_after() {
        let store = ProfileStore::new(None);
        store.set_away(away(1_000, 5_000));
        assert!(store.current(4_999).is_some(), "inside the window");
        assert_eq!(
            store.zone(4_999).iana_name().as_deref(),
            Some("Europe/London")
        );
        // At the instant `until` names, and after it, the profile is gone.
        assert!(store.current(5_000).is_none(), "the boundary is exclusive");
        assert_eq!(store.zone(5_000), SchedulerZone::Host);
        // ...but the record is still there, and its return is owed.
        assert!(store.stored().is_some());
        assert!(store.return_owed(5_000).is_some());
    }

    #[test]
    fn coming_home_early_ends_the_period_and_still_owes_the_return() {
        let store = ProfileStore::new(None);
        store.set_away(away(1_000, 900_000));
        let ended = store.go_home(4_000).expect("a live period was ended");
        assert_eq!(ended.until_ms, Some(4_000));
        assert!(store.current(4_000).is_none(), "home takes effect at once");
        assert_eq!(store.zone(4_000), SchedulerZone::Host);
        assert!(
            store.return_owed(4_000).is_some(),
            "an early return is still a return"
        );
        // Coming home twice is a no-op, not a second period to return from.
        assert!(store.go_home(5_000).is_none());
    }

    #[test]
    fn a_return_is_owed_once_and_survives_a_store_reload() {
        let path = temp_profile_path();
        {
            let store = ProfileStore::new(Some(path.clone()));
            store.set_away(away(1_000, 5_000));
            assert!(store.return_owed(6_000).is_some());
            store.mark_returned(6_000);
            assert!(store.return_owed(6_000).is_none(), "fired once");
        }
        let reloaded = ProfileStore::new(Some(path.clone()));
        assert!(
            reloaded.return_owed(6_000).is_none(),
            "and not again after a restart"
        );
        assert_eq!(reloaded.returned_ms(), Some(6_000));

        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "profile.json must be 0600");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_corrupt_file_loads_as_home_and_the_store_is_still_usable() {
        let path = temp_profile_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "not json at all {").unwrap();
        let store = ProfileStore::new(Some(path.clone()));
        assert!(store.current(1_000).is_none());
        store.set_away(away(1_000, 5_000));
        let reloaded = ProfileStore::new(Some(path.clone()));
        assert!(reloaded.current(2_000).is_some());
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// A stored zone this tz database cannot resolve is dropped, not half-honoured.
    #[test]
    fn a_record_naming_an_unknown_zone_loads_as_home() {
        let path = temp_profile_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            &path,
            r#"{"v":1,"profile":{"name":"away","tz":"Mars/Olympus","since_ms":1,"until_ms":9999999999999,"note":""}}"#,
        )
        .unwrap();
        let store = ProfileStore::new(Some(path.clone()));
        assert!(store.current(1_000).is_none(), "unknown zone → home");
        assert!(store.stored().is_none());
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    // ---- effective_tz precedence --------------------------------------------

    #[test]
    fn the_client_zone_outranks_the_profile_which_outranks_the_process() {
        let store = ProfileStore::new(None);
        // 3. Nothing set → the process zone, which is what every path used before.
        assert_eq!(effective_tz(None, &store, 1_000), SchedulerZone::Host);
        // 2. A profile, and no client.
        store.set_away(away(1_000, 900_000));
        assert_eq!(
            effective_tz(None, &store, 2_000).iana_name().as_deref(),
            Some("Europe/London")
        );
        // 1. A client that says where it is wins over both.
        assert_eq!(
            effective_tz(Some("America/New_York"), &store, 2_000)
                .iana_name()
                .as_deref(),
            Some("America/New_York")
        );
        // An unparseable or blank client zone falls through rather than failing.
        assert_eq!(
            effective_tz(Some("Mars/Olympus"), &store, 2_000)
                .iana_name()
                .as_deref(),
            Some("Europe/London")
        );
        assert_eq!(
            effective_tz(Some("   "), &store, 2_000)
                .iana_name()
                .as_deref(),
            Some("Europe/London")
        );
    }

    #[test]
    fn days_away_counts_local_days_not_elapsed_millis() {
        // 22:00 on the 25th to 08:00 on the 26th is 10 hours — and one day.
        use chrono::TimeZone;
        let since = chrono_tz::Europe::London
            .with_ymd_and_hms(2026, 8, 25, 22, 0, 0)
            .unwrap()
            .timestamp_millis() as u64;
        let back = chrono_tz::Europe::London
            .with_ymd_and_hms(2026, 8, 26, 8, 0, 0)
            .unwrap()
            .timestamp_millis() as u64;
        assert_eq!(away(since, back).days_away(back), 1);
    }

    #[test]
    fn profile_names_round_trip_case_insensitively() {
        assert_eq!(ProfileName::parse("away"), Some(ProfileName::Away));
        assert_eq!(ProfileName::parse(" HOME "), Some(ProfileName::Home));
        assert_eq!(ProfileName::parse("holiday"), None);
        assert_eq!(ProfileName::Away.label(), "away");
    }
}
