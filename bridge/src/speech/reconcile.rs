//! Two readings of one recording, reconciled into a transcript and a DISAGREEMENT LIST.
//!
//! The purpose of the second reading is not to average two transcripts. It is to find where
//! the transcript is UNCERTAIN. In field testing two strong engines on conditioned audio
//! agreed on almost everything and disagreed on exactly the things that mattered — a surname,
//! a pickup date — and the right reading of the date was the one whose weekday matched the
//! calendar. A person listening would have caught that; a transcript that silently picked one
//! reading would not. So:
//!
//! * where the engines agree, the shared reading stands;
//! * where they differ, the PRIMARY reading stays in the transcript and the alternative is
//!   kept beside it in a [`Disagreement`], with the time range to find it by.
//!
//! The raw transcript is authoritative and this never edits it. The disagreement list is
//! additive: it travels with the transcript so whatever reads it next — a person, or the
//! model the message is sent to — can resolve a specific the way a listener would.
//!
//! The comparison is shaped after `crate::vision`'s helper comparison, which runs more than one
//! helper over one image and keeps each result attributed: here too every alternative is
//! labelled with the engine that produced it, and both engines are named in the result.
//!
//! Alignment is a word-level Myers diff over normalized words (case and punctuation folded,
//! so "St." and "st" agree), with the segments' timestamps carried along for the ranges.

use super::engine::Segment;

/// A pause at least this long starts a new paragraph in the transcript.
pub const PARAGRAPH_GAP_MS: u64 = 2_500;
/// More disagreements than this are counted, not listed.
pub const MAX_DISAGREEMENTS: usize = 200;
/// Past this many word edits the two readings are not describing the same audio closely
/// enough for a word-by-word list to mean anything, and the alignment stops.
pub const MAX_EDITS: usize = 3_000;

/// One place the two readings differ.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct Disagreement {
    pub start_ms: u64,
    pub end_ms: u64,
    /// The primary reading — what the transcript says here.
    pub primary: String,
    /// What the second engine heard instead. Empty when it heard nothing there.
    pub alternative: String,
}

/// The comparison.
#[derive(Debug, Clone, PartialEq)]
pub struct Reconciled {
    pub disagreements: Vec<Disagreement>,
    /// Share of the primary reading's words the second reading matched, 0.0 to 1.0.
    pub agreement: f32,
    /// Anything the reader should know about the comparison itself.
    pub note: Option<String>,
}

/// Fold a word for comparison: letters and digits only, lowercased. "St." and "st" agree,
/// "4,250" and "4250" agree, "14th" and "15th" do not.
pub fn norm_word(w: &str) -> String {
    w.chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

/// The transcript's text: segments joined, with a paragraph break at each long pause.
pub fn transcript_text(segments: &[Segment]) -> String {
    let mut out = String::new();
    let mut last_end: Option<u64> = None;
    for s in segments {
        let text = s.text.trim();
        if text.is_empty() {
            continue;
        }
        if let Some(end) = last_end {
            if s.start_ms.saturating_sub(end) >= PARAGRAPH_GAP_MS {
                out.push_str("\n\n");
            } else {
                out.push(' ');
            }
        }
        out.push_str(text);
        last_end = Some(s.end_ms);
    }
    out
}

struct Word<'a> {
    raw: &'a str,
    norm: String,
    start_ms: u64,
    end_ms: u64,
}

fn words(segments: &[Segment]) -> Vec<Word<'_>> {
    segments
        .iter()
        .flat_map(|s| {
            s.text.split_whitespace().filter_map(move |raw| {
                let norm = norm_word(raw);
                (!norm.is_empty()).then_some(Word {
                    raw,
                    norm,
                    start_ms: s.start_ms,
                    end_ms: s.end_ms,
                })
            })
        })
        .collect()
}

/// Compare the primary reading with a second one.
pub fn reconcile(primary: &[Segment], alternative: &[Segment]) -> Reconciled {
    let a = words(primary);
    let b = words(alternative);
    let an: Vec<&str> = a.iter().map(|w| w.norm.as_str()).collect();
    let bn: Vec<&str> = b.iter().map(|w| w.norm.as_str()).collect();
    let Some(ops) = diff(&an, &bn, MAX_EDITS) else {
        return Reconciled {
            disagreements: Vec::new(),
            agreement: 0.0,
            note: Some(format!(
                "The two readings differ in more than {MAX_EDITS} words, so they were not \
                 compared word by word. Treat names, numbers and dates in this transcript \
                 with care."
            )),
        };
    };

    // Group the edits into hunks, merging two hunks separated by a single agreeing word, so
    // "Marta Esposito" against "Marvin Espino" is one disagreement rather than two.
    struct Hunk {
        a0: usize,
        a1: usize,
        b0: usize,
        b1: usize,
    }
    const MERGE_GAP: usize = 1;
    let mut hunks: Vec<Hunk> = Vec::new();
    let mut open: Option<Hunk> = None;
    let mut gap = 0usize;
    let (mut ai, mut bj) = (0usize, 0usize);
    let mut matched = 0usize;
    for op in &ops {
        let (a_before, b_before) = (ai, bj);
        match *op {
            Op::Eq(i, j) => {
                ai = i + 1;
                bj = j + 1;
                matched += 1;
                gap += 1;
                continue;
            }
            Op::Del(i) => ai = i + 1,
            Op::Ins(j) => bj = j + 1,
        }
        match open.as_mut() {
            Some(h) if gap <= MERGE_GAP => {
                h.a1 = ai;
                h.b1 = bj;
            }
            _ => {
                if let Some(h) = open.take() {
                    hunks.push(h);
                }
                open = Some(Hunk {
                    a0: a_before,
                    a1: ai,
                    b0: b_before,
                    b1: bj,
                });
            }
        }
        gap = 0;
    }
    if let Some(h) = open {
        hunks.push(h);
    }

    let mut disagreements: Vec<Disagreement> = hunks
        .iter()
        .filter(|h| !trivial(&a[h.a0..h.a1], &b[h.b0..h.b1]))
        .map(|h| {
            let side = |ws: &[Word]| ws.iter().map(|w| w.raw).collect::<Vec<_>>().join(" ");
            let timed = if h.a1 > h.a0 {
                &a[h.a0..h.a1]
            } else {
                &b[h.b0..h.b1]
            };
            Disagreement {
                start_ms: timed.iter().map(|w| w.start_ms).min().unwrap_or(0),
                end_ms: timed.iter().map(|w| w.end_ms).max().unwrap_or(0),
                primary: side(&a[h.a0..h.a1]),
                alternative: side(&b[h.b0..h.b1]),
            }
        })
        .collect();
    let mut note = None;
    if disagreements.len() > MAX_DISAGREEMENTS {
        note = Some(format!(
            "{} further disagreements were not listed.",
            disagreements.len() - MAX_DISAGREEMENTS
        ));
        disagreements.truncate(MAX_DISAGREEMENTS);
    }
    Reconciled {
        disagreements,
        agreement: if a.is_empty() {
            if b.is_empty() {
                1.0
            } else {
                0.0
            }
        } else {
            matched as f32 / a.len() as f32
        },
        note,
    }
}

/// Words one engine writes and the other leaves out WITHOUT changing what was said: articles
/// and fillers, and the spelled-out form of a sign the other engine wrote as a sign ("€4,250"
/// against "4,250 euros"). Deliberately short, and deliberately a LIST rather than a length:
/// the short words carry the most meaning per letter, and "the pickup is not on Friday"
/// against "the pickup is on Friday" must never be filtered out as noise.
const INERT_WORDS: &[&str] = &[
    // English articles and fillers.
    "the", "a", "an", "uh", "um", "er", "erm", "ah", "oh", "mm", "hmm", "okay", "ok",
    // Italian articles and fillers.
    "il", "lo", "la", "i", "gli", "le", "un", "uno", "una", "ehm", "eh",
    // Signs one engine spells out.
    "euro", "euros", "dollar", "dollars", "percent",
];

/// A difference not worth a reader's attention: one side heard nothing and the other a
/// single [`INERT_WORDS`] word — "on the Friday" against "on Friday". Any other one-sided
/// word is listed, a digit or a "not" above all.
fn trivial(a: &[Word], b: &[Word]) -> bool {
    let inert = |ws: &[Word]| ws.len() == 1 && INERT_WORDS.contains(&ws[0].norm.as_str());
    (a.is_empty() && inert(b)) || (b.is_empty() && inert(a))
}

/// One step of an edit script.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Op {
    Eq(usize, usize),
    Del(usize),
    Ins(usize),
}

/// Myers' O((N+M)D) shortest edit script, or `None` past `max_edits`. The trace keeps only the
/// diagonals each step can reach, so memory grows with D² rather than D·(N+M).
fn diff(a: &[&str], b: &[&str], max_edits: usize) -> Option<Vec<Op>> {
    let n = a.len() as i64;
    let m = b.len() as i64;
    let limit = ((n + m) as usize).min(max_edits) as i64;
    let off = limit + 1;
    let mut v = vec![0i64; (2 * limit + 3) as usize];
    let at = |k: i64| (k + off) as usize;
    let mut trace: Vec<Vec<i32>> = Vec::new();
    for d in 0..=limit {
        trace.push((-d - 1..=d + 1).map(|k| v[at(k)] as i32).collect());
        let mut k = -d;
        while k <= d {
            let down = k == -d || (k != d && v[at(k - 1)] < v[at(k + 1)]);
            let mut x = if down { v[at(k + 1)] } else { v[at(k - 1)] + 1 };
            let mut y = x - k;
            while x < n && y < m && a[x as usize] == b[y as usize] {
                x += 1;
                y += 1;
            }
            v[at(k)] = x;
            if x >= n && y >= m {
                return Some(backtrack(&trace, n, m));
            }
            k += 2;
        }
    }
    None
}

fn backtrack(trace: &[Vec<i32>], n: i64, m: i64) -> Vec<Op> {
    let mut ops = Vec::new();
    let (mut x, mut y) = (n, m);
    for d in (0..trace.len() as i64).rev() {
        let snap = &trace[d as usize];
        let get = |k: i64| snap[(k + d + 1) as usize] as i64;
        let k = x - y;
        let down = k == -d || (k != d && get(k - 1) < get(k + 1));
        let prev_k = if down { k + 1 } else { k - 1 };
        let prev_x = get(prev_k);
        let prev_y = prev_x - prev_k;
        while x > prev_x && y > prev_y {
            ops.push(Op::Eq((x - 1) as usize, (y - 1) as usize));
            x -= 1;
            y -= 1;
        }
        if d > 0 {
            if down {
                ops.push(Op::Ins((y - 1) as usize));
            } else {
                ops.push(Op::Del((x - 1) as usize));
            }
        }
        x = prev_x;
        y = prev_y;
    }
    ops.reverse();
    ops
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(start_s: u64, end_s: u64, text: &str) -> Segment {
        Segment::new(start_s * 1_000, end_s * 1_000, text)
    }

    #[test]
    fn identical_readings_have_nothing_to_report() {
        let p = vec![
            seg(0, 4, "Good evening everyone."),
            seg(4, 7, "A few practical things."),
        ];
        let r = reconcile(&p, &p);
        assert!(r.disagreements.is_empty());
        assert_eq!(r.agreement, 1.0);
        assert_eq!(r.note, None);
    }

    /// THE FIELD CASE: two engines disagree on a pickup date. Both readings survive, the
    /// primary one in the transcript and the alternative in the list, with the time to find
    /// it by.
    #[test]
    fn a_disputed_date_is_listed_with_both_readings_and_its_time() {
        let p = vec![
            seg(0, 6, "The collection will be picked up"),
            seg(6, 11, "on Thursday the 14th of November."),
        ];
        let alt = vec![seg(
            0,
            11,
            "The collection will be picked up on Thursday the 15th of November.",
        )];
        let r = reconcile(&p, &alt);
        assert_eq!(
            r.disagreements,
            vec![Disagreement {
                start_ms: 6_000,
                end_ms: 11_000,
                primary: "14th".to_string(),
                alternative: "15th".to_string(),
            }]
        );
        assert!(r.agreement > 0.9);
    }

    #[test]
    fn adjacent_differences_are_one_disagreement_not_several() {
        let p = vec![seg(
            21,
            30,
            "the new boiler, which Marta Esposito will order from Ancona.",
        )];
        let alt = vec![seg(
            21,
            30,
            "the new board, which Marvin Espino will order from Oncona.",
        )];
        let r = reconcile(&p, &alt);
        let listed: Vec<(&str, &str)> = r
            .disagreements
            .iter()
            .map(|d| (d.primary.as_str(), d.alternative.as_str()))
            .collect();
        assert_eq!(
            listed,
            vec![
                ("boiler, which Marta Esposito", "board, which Marvin Espino"),
                ("Ancona.", "Oncona."),
            ]
        );
    }

    #[test]
    fn case_and_punctuation_are_not_disagreements() {
        let p = vec![seg(0, 3, "St. Vincent pantry, €4,250.")];
        let alt = vec![seg(0, 3, "st vincent Pantry 4250")];
        assert!(reconcile(&p, &alt).disagreements.is_empty());
    }

    #[test]
    fn an_article_or_a_spelled_out_sign_is_noise_but_a_missing_not_or_number_is_not() {
        let p = vec![seg(0, 3, "not on the Friday as it said")];
        let alt = vec![seg(0, 3, "not on Friday as it said")];
        assert!(
            reconcile(&p, &alt).disagreements.is_empty(),
            "\"the\" is noise"
        );

        // Found by the end-to-end run: one engine writes the sign, the other the word.
        let p = vec![seg(21, 28, "agreed to spend €4,250 on the new boiler")];
        let alt = vec![seg(21, 28, "agreed to spend 4,250 euros on the new boiler")];
        assert!(
            reconcile(&p, &alt).disagreements.is_empty(),
            "€ and euros say the same"
        );

        // The short words carry the most meaning per letter. A length rule would hide this.
        let p = vec![seg(0, 3, "the pickup is not on Friday")];
        let alt = vec![seg(0, 3, "the pickup is on Friday")];
        let r = reconcile(&p, &alt);
        assert_eq!(
            r.disagreements.len(),
            1,
            "a missing \"not\" reverses the sentence"
        );
        assert_eq!(r.disagreements[0].primary, "not");
        assert_eq!(r.disagreements[0].alternative, "");

        let p = vec![seg(0, 3, "picked up on the 14th")];
        let alt = vec![seg(0, 3, "picked up on the")];
        let r = reconcile(&p, &alt);
        assert_eq!(r.disagreements.len(), 1, "a missing number matters");
        assert_eq!(r.disagreements[0].alternative, "");
    }

    #[test]
    fn readings_that_share_almost_nothing_are_not_forced_into_a_list() {
        let p: Vec<Segment> = (0..(MAX_EDITS as u64 / 4 + 10))
            .map(|i| seg(i, i + 1, &format!("alpha{i} beta{i} gamma{i}")))
            .collect();
        let alt: Vec<Segment> = (0..(MAX_EDITS as u64 / 4 + 10))
            .map(|i| seg(i, i + 1, &format!("delta{i} epsilon{i} zeta{i}")))
            .collect();
        let r = reconcile(&p, &alt);
        assert!(r.disagreements.is_empty());
        assert!(r.note.unwrap().contains("not compared word by word"));
    }

    /// The edit script is a real one: applying it rebuilds both sides, on inputs chosen to
    /// exercise every branch (empty sides, pure insertions, pure deletions, interleavings).
    #[test]
    fn the_diff_reconstructs_both_sides() {
        let mut seed = 0x9E37_79B9u32;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed
        };
        let vocab = ["a", "b", "c", "d"];
        for _ in 0..400 {
            let la = (next() % 12) as usize;
            let lb = (next() % 12) as usize;
            let a: Vec<&str> = (0..la).map(|_| vocab[(next() % 4) as usize]).collect();
            let b: Vec<&str> = (0..lb).map(|_| vocab[(next() % 4) as usize]).collect();
            let ops = diff(&a, &b, 1_000).expect("small inputs always align");
            let mut ra = Vec::new();
            let mut rb = Vec::new();
            for op in ops {
                match op {
                    Op::Eq(i, j) => {
                        assert_eq!(a[i], b[j]);
                        ra.push(a[i]);
                        rb.push(b[j]);
                    }
                    Op::Del(i) => ra.push(a[i]),
                    Op::Ins(j) => rb.push(b[j]),
                }
            }
            assert_eq!(ra, a);
            assert_eq!(rb, b);
        }
    }

    #[test]
    fn long_pauses_become_paragraphs() {
        let t = transcript_text(&[
            seg(0, 3, "Good evening."),
            seg(3, 5, "A few things."),
            seg(9, 12, "Now the budget."),
            seg(12, 12, "  "),
        ]);
        assert_eq!(t, "Good evening. A few things.\n\nNow the budget.");
    }
}
