use crate::*;

// ---- Live streaming (SSE) -------------------------------------------------

/// How many SSE events can queue toward one client before its forwarder applies
/// backpressure. Small: the forwarder uses `send().await`, and the broadcast
/// backlog (`STREAM_CHANNEL_CAP`) is the real buffer.
pub const SSE_FORWARD_BUFFER: usize = 64;

/// The SSE response body: a thin `Stream` over an mpsc receiver fed by a
/// forwarder task (or pre-seeded with terminal frames). tokio's `mpsc::Receiver`
/// exposes `poll_recv`, so this needs only `futures_core::Stream` — no extra
/// stream-adapter dependency. The error type is `Infallible`: a dropped client
/// just ends the stream, it never errors.
pub struct SseBody {
    rx: mpsc::Receiver<Result<Event, std::convert::Infallible>>,
}

impl Stream for SseBody {
    type Item = Result<Event, std::convert::Infallible>;
    fn poll_next(mut self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<Option<Self::Item>> {
        self.rx.poll_recv(cx)
    }
}

/// Build a named SSE event whose data is a single-line JSON object. JSON-encoding
/// the payload guarantees no raw newline/CR ever reaches `Event::data` (which
/// would split the frame or panic), and keeps one logical frame == one `data:`.
pub fn sse_event(kind: &str, data: Value) -> Event {
    Event::default().event(kind).data(data.to_string())
}

/// A `reset` frame carrying the full text the client should now show. Used for
/// the initial replay of text-so-far and to re-sync a subscriber that lagged the
/// broadcast backlog — the client REPLACES its buffer with this, vs appending a
/// `delta`.
pub fn sse_reset(text: &str) -> Event {
    sse_event("reset", json!({ "text": text }))
}

/// Translate a broadcast `StreamFrame` into its wire SSE event.
pub fn frame_to_event(frame: &StreamFrame) -> Event {
    match frame {
        StreamFrame::Delta(text) => sse_event("delta", json!({ "text": text })),
        StreamFrame::Activity(name) => sse_event("activity", json!({ "name": name })),
        StreamFrame::Done {
            response,
            session_id,
            directives,
            provenance,
        } => sse_event(
            "done",
            json!({
                "response": response,
                "session_id": session_id,
                "directives": directives_to_value(directives),
                "provenance": provenance_to_value(provenance.as_deref()),
            }),
        ),
        StreamFrame::Error(error) => sse_event("error", json!({ "error": error })),
        StreamFrame::Cancelled => sse_event("cancelled", json!({})),
    }
}

/// Forward one subscriber's broadcast frames to its SSE mpsc until a terminal
/// frame arrives, the client goes away (mpsc send fails), or the sender closes.
/// Extracted from `jesse_stream` so the lag-recovery path is directly testable.
///
/// The load-bearing branch: if the subscriber falls behind the broadcast backlog
/// (`RecvError::Lagged`), instead of dropping the missed deltas it resends the
/// FULL accumulated text as a single `reset`, so the client re-syncs and never
/// silently loses content — correctness never depends on the channel capacity.
pub async fn forward_live_frames(
    mut brx: broadcast::Receiver<StreamFrame>,
    tx: mpsc::Sender<Result<Event, std::convert::Infallible>>,
    jobs: Arc<JobStore>,
    jid: String,
) {
    loop {
        match brx.recv().await {
            Ok(frame) => {
                let terminal = matches!(
                    frame,
                    StreamFrame::Done { .. } | StreamFrame::Error(_) | StreamFrame::Cancelled
                );
                if tx.send(Ok(frame_to_event(&frame))).await.is_err() {
                    break; // client disconnected
                }
                if terminal {
                    break;
                }
            }
            // Fell behind the backlog — re-sync by resending the full accumulated
            // text, so no delta is silently lost.
            Err(broadcast::error::RecvError::Lagged(_)) => {
                let snapshot = jobs.stream_snapshot(&jid).unwrap_or_default();
                if tx.send(Ok(sse_reset(&snapshot))).await.is_err() {
                    break;
                }
            }
            // Sender dropped without a terminal frame (e.g. the bridge is shutting
            // down). End the stream; the client falls back to poll.
            Err(broadcast::error::RecvError::Closed) => break,
        }
    }
}

/// `GET /jesse/stream/:job_id` — Server-Sent Events for one turn. Same bearer
/// auth as `/jesse`. The phone opens this after `POST /jesse` hands back a
/// `job_id` and renders the reply as it streams.
///
/// On subscribe to a RUNNING job: replay the text accumulated so far (a `reset`
/// frame) plus the latest activity, then forward live frames — `delta`,
/// `activity`, and one terminal `done` / `error` / `cancelled`. If the job is
/// already TERMINAL when the stream opens, emit the matching terminal frame
/// immediately (replaying full text + `done` for a finished turn) and close.
/// Unknown/expired id → 404. `GET /jesse/result/:job_id` remains the poll
/// fallback and is unaffected.
pub async fn jesse_stream(
    State(st): State<AppState>,
    UrlPath(job_id): UrlPath<String>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;

    let (tx, rx) = mpsc::channel::<Result<Event, std::convert::Infallible>>(SSE_FORWARD_BUFFER);

    if let Some((text, activity, brx)) = st.jobs.stream_subscribe(&job_id) {
        // Live job: replay text-so-far (+ any activity), then forward broadcast
        // frames on a task that ends when the terminal frame arrives or the
        // client goes away (the mpsc send fails once the response body is dropped).
        let _ = tx.try_send(Ok(sse_reset(&text)));
        if let Some(name) = activity {
            let _ = tx.try_send(Ok(sse_event("activity", json!({ "name": name }))));
        }
        tokio::spawn(forward_live_frames(
            brx,
            tx,
            st.jobs.clone(),
            job_id.clone(),
        ));
    } else {
        // No live stream — the job is already terminal (or never existed). Emit
        // the matching frame and close. `get_retrieving` so an already-`done`
        // job opened only via the stream still starts its post-fetch grace.
        match st.jobs.get_retrieving(&job_id) {
            Some(JobState::Done {
                response,
                session_id,
                directives,
                provenance,
            }) => {
                let _ = tx.try_send(Ok(sse_reset(&response)));
                let _ = tx.try_send(Ok(sse_event(
                    "done",
                    json!({
                        "response": response,
                        "session_id": session_id,
                        "directives": directives_to_value(&directives),
                        "provenance": provenance_to_value(provenance.as_deref()),
                    }),
                )));
            }
            Some(JobState::Failed { error }) => {
                let _ = tx.try_send(Ok(sse_event("error", json!({ "error": error }))));
            }
            Some(JobState::Cancelled) => {
                let _ = tx.try_send(Ok(sse_event("cancelled", json!({}))));
            }
            // Running without a stream handle shouldn't happen (the handle is
            // registered before the turn spawns and removed only at the terminal
            // transition), but if it does, send nothing and let the client poll.
            Some(JobState::Running) => {}
            None => {
                return Err((
                    StatusCode::NOT_FOUND,
                    "unknown or expired job id".to_string(),
                ))
            }
        }
        // `tx` drops here (not moved into a task), so the stream ends once the
        // queued terminal frames have been read.
    }

    Ok(Sse::new(SseBody { rx })
        .keep_alive(KeepAlive::default())
        .into_response())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::to_bytes;

    // Forces a subscriber to fall behind the broadcast backlog (RecvError::Lagged)
    // and asserts the forwarder re-sends the FULL accumulated text as a single
    // `reset`, rather than silently dropping the deltas it missed.
    #[tokio::test]
    async fn lagged_subscriber_is_resynced_with_a_full_reset() {
        let jobs = Arc::new(JobStore::new(
            Duration::from_secs(600),
            Duration::from_secs(600),
            None,
        ));
        let id = jobs.create();
        jobs.stream_register(&id);

        // Subscribe first, then flood the sender well past STREAM_CHANNEL_CAP
        // (1024) WITHOUT this receiver consuming anything, so it is guaranteed to
        // lag. A recognizable single-char delta means the only place the full
        // contiguous run can appear on the wire is the re-sync `reset`.
        let (_text, _activity, brx) = jobs.stream_subscribe(&id).unwrap();
        for _ in 0..1100 {
            jobs.stream_push_delta(&id, "x");
        }
        let full = jobs.stream_snapshot(&id).unwrap();
        assert_eq!(full.len(), 1100, "accumulator holds every delta");
        // A terminal frame (also the newest broadcast message, so it survives in
        // the ring after the lag) lets the forwarder finish and close the body.
        jobs.stream_finish(
            &id,
            StreamFrame::Done {
                response: full.clone(),
                session_id: None,
                directives: None,
                provenance: None,
            },
        );

        let (tx, rx) = mpsc::channel::<Result<Event, std::convert::Infallible>>(64);
        tokio::spawn(forward_live_frames(brx, tx, jobs.clone(), id.clone()));

        // Serialize the forwarded events to the SSE wire and inspect them.
        let resp = Sse::new(SseBody { rx }).into_response();
        let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let wire = String::from_utf8(bytes.to_vec()).unwrap();

        assert!(
            wire.contains("event: reset"),
            "a lagged subscriber must get a reset frame: {}",
            &wire[..wire.len().min(200)]
        );
        // The 1100-char contiguous run appears ONLY in the re-sync reset (the
        // replayed deltas are one char each, frame-separated), so this proves the
        // reset carried the full accumulated text.
        assert!(
            wire.contains(&full),
            "the reset must carry the full accumulated text, not a truncated one"
        );
    }
}
