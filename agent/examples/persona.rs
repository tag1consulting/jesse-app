//! Print the persona pack, what it renders to, and what the checker makes of three replies.
//!
//! An EXAMPLE rather than a test, for the reason `manifest.rs` is one: its output is meant to
//! be read by a person and pasted into a report, and a test whose value is its stdout is a
//! test nobody runs. Every property it demonstrates is asserted properly in
//! `src/persona/{mod,render,check}.rs`.
//!
//! **EVERY STRING BELOW IS A FIXTURE.** Nothing is read from a vault, a config file or the
//! environment, so the output is the same on every machine and carries nobody's prose.
//!
//! ```text
//!   cargo run -p jesse-agent --example persona
//! ```
use jesse_agent::persona::{
    check, render, AddressStyle, AssistantIdentity, Correction, Dashes, Emoji, Formality,
    FormattingParams, Headings, Hedging, Humor, Lists, OwnerIdentity, Pattern, PersonaPack,
    Questions, StyleParams, StyleReport, Verbosity, WritingSample,
};
use jesse_agent::provider::Wire;

fn main() {
    let default = PersonaPack::default();
    let populated = populated();

    rule("1. THE PACK SCHEMA (the default pack, as JSON)");
    println!(
        "{}",
        serde_json::to_string_pretty(&default).expect("serialises")
    );

    rule("2. A FULLY POPULATED FIXTURE PACK (as JSON)");
    println!(
        "{}",
        serde_json::to_string_pretty(&populated).expect("serialises")
    );

    rule("3. RENDERED PERSONA BLOCKS: the DEFAULT pack, wire=messages");
    print_blocks(&default, Wire::Messages);

    rule("4. RENDERED PERSONA BLOCKS: the FIXTURE pack, wire=messages");
    print_blocks(&populated, Wire::Messages);

    rule("5. THE SAME FIXTURE PACK ON wire=chat (placement only)");
    print_blocks(&populated, Wire::Chat);
    println!(
        "\nconcatenated text identical across wires: {}",
        joined(&populated, Wire::Messages) == joined(&populated, Wire::Chat)
    );

    rule("6. THE CHECKER ON THREE FIXTURE REPLIES");
    for (label, reply) in [
        ("clean", CLEAN),
        ("dashes only", DASHES),
        ("banned phrases", BANNED),
    ] {
        let report = check(reply, &populated);
        println!("--- {label} ---");
        println!("  bytes={} lines={}", reply.len(), reply.lines().count());
        print_report(&report);
    }

    rule("7. BYTE SIZES OF THE RENDERED BLOCKS (sizes only)");
    for (label, pack) in [("default", &default), ("fixture", &populated)] {
        for wire in [Wire::Messages, Wire::Chat] {
            let blocks = render(pack, wire);
            let sizes: Vec<usize> = blocks.iter().map(|b| b.text.len()).collect();
            println!(
                "  {label:<8} wire={wire:<8} blocks={} bytes={} per-block={sizes:?}",
                blocks.len(),
                sizes.iter().sum::<usize>()
            );
        }
    }
}

fn rule(title: &str) {
    println!("\n==== {title} ====\n");
}

fn print_blocks(pack: &PersonaPack, wire: Wire) {
    for (i, b) in render(pack, wire).iter().enumerate() {
        println!(
            "[block {} cacheable={} bytes={}]\n{}\n",
            i + 1,
            b.cacheable,
            b.text.len(),
            b.text
        );
    }
}

fn joined(pack: &PersonaPack, wire: Wire) -> String {
    render(pack, wire)
        .iter()
        .map(|b| b.text.as_str())
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// The report, printed exactly as content free as it is: pattern sources, line numbers and
/// match lengths. There is no excerpt to print.
fn print_report(report: &StyleReport) {
    println!(
        "  total={} dash_hits={} list_hits={} heading_hits={}",
        report.total(),
        report.dash_hits,
        report.list_hits,
        report.heading_hits
    );
    for h in &report.hits {
        println!(
            "  hit: pattern={:?} line={} excerpt_len={}",
            h.pattern_source, h.line, h.excerpt_len
        );
    }
}

const CLEAN: &str = "The archive holds 212 documents. Nothing in it needs your attention \
                     today, and the two you asked about were both last touched in June.";

const DASHES: &str = "The archive holds 212 documents \u{2014} nothing in it needs your \
                      attention today.\nThe two you asked about \u{2013} both of them \u{2014} \
                      were last touched in June.\nRun `git log --oneline` to see them.";

const BANNED: &str = "Let us delve into the archive, which stands as a testament to careful \
                      record keeping.\nIt is a comprehensive and robust collection, and \
                      delving further would be worthwhile.";

fn populated() -> PersonaPack {
    PersonaPack {
        version: 1,
        languages: vec!["en".into(), "it".into()],
        banned_patterns: [
            r"\bdelve\b",
            r"\bcomprehensive\b",
            r"\brobust\b",
            "stands as a testament to",
        ]
        .iter()
        .map(|p| Pattern::new(*p).expect("compiles"))
        .collect(),
        free_text: Some(
            "Answer the question I asked, not the one you wish I had asked. If you cannot \
             answer it, say so in the first sentence."
                .into(),
        ),
        assistant: AssistantIdentity {
            name: "Ada".into(),
            self_description: Some("a research assistant for a working archive".into()),
        },
        owner: OwnerIdentity {
            name: "Alex Example".into(),
            pronoun: "their".into(),
            address_style: AddressStyle::ByName,
        },
        style: StyleParams {
            formality: Formality::Low,
            humor: Humor::Dry,
            verbosity: Verbosity::Terse,
            emoji: Emoji::Never,
            hedging: Hedging::Minimal,
            questions: Questions::AssumeAndState,
        },
        formatting: FormattingParams {
            lists: Lists::Avoid,
            headings: Headings::Avoid,
            dashes: Dashes::Forbidden,
        },
        writing_samples: vec![WritingSample {
            title: "A note about the archive".into(),
            text: "The archive is not a museum. Things in it get used, and the ones that stop \
                   being used get thrown away."
                .into(),
            source: Some("fixture.md".into()),
        }],
        corrections: vec![Correction {
            rule: "always put the time in the subject line".into(),
            added_at: "2026-08-28T08:36:00Z".into(),
            source: Some("fixture".into()),
        }],
    }
}
