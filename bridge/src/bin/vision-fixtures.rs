//! `vision-fixtures` — regenerate the fixed vision eval set under `eval/vision/fixtures/`.
//! Deterministic and dependency-light: the PDFs are emitted with hand-computed xref
//! offsets (valid, and openable by any conforming reader) and the images with the `image`
//! crate. Run once and commit the output; `vision-eval` reads `eval/vision/manifest.json`
//! against them, and the bridge's rasterizer tests read `multipage.pdf` directly.
//!
//! The text/table PDFs carry REAL text, so their ground-truth strings are a meaningful
//! faithfulness check. The chart/screenshot/photo PNGs are SYNTHETIC placeholders (shapes
//! and colors, little text) — enough to exercise the image path end to end; swap in
//! representative real-world uploads before the definitive fidelity-vs-cost call.
//!
//! Usage:  vision-fixtures <output-dir>      (e.g. ./eval/vision/fixtures)

use image::{ImageBuffer, Rgb, RgbImage};
use std::io::Write;
use std::path::Path;

fn main() {
    let dir = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "eval/vision/fixtures".to_string());
    let dir = Path::new(&dir);
    std::fs::create_dir_all(dir).expect("create fixtures dir");

    // 1. Text-heavy PDF — an invoice-like page of prose + line items.
    let statement = text_pdf(&[
        (72.0, 720.0, 20.0, "ACME WIDGETS — INVOICE"),
        (72.0, 690.0, 12.0, "Invoice Number: INV-2026-0042"),
        (72.0, 672.0, 12.0, "Date: 2026-07-24"),
        (
            72.0,
            654.0,
            12.0,
            "Bill To: Globex SRL, 1 Example Way, Springfield",
        ),
        (
            72.0,
            620.0,
            12.0,
            "Description                 Qty     Amount",
        ),
        (
            72.0,
            602.0,
            12.0,
            "Fiber install (annual)       1      EUR 480.00",
        ),
        (
            72.0,
            584.0,
            12.0,
            "Static IP block              1      EUR 120.00",
        ),
        (72.0, 560.0, 14.0, "Total Due: EUR 600.00"),
        (
            72.0,
            520.0,
            11.0,
            "Payment terms: net 30. Thank you for your business.",
        ),
    ]);
    write(dir.join("statement.pdf"), &statement);

    // 2. Table PDF — a small values table (text positioned in columns).
    let table = text_pdf(&[
        (72.0, 720.0, 16.0, "QUARTERLY REVENUE (EUR thousands)"),
        (72.0, 690.0, 12.0, "Quarter    North     South      Total"),
        (72.0, 672.0, 12.0, "Q1 2026    412       88         500"),
        (72.0, 654.0, 12.0, "Q2 2026    455       102        557"),
        (72.0, 636.0, 12.0, "Q3 2026    470       121        591"),
        (72.0, 612.0, 12.0, "Full Year  1801      402        2203"),
    ]);
    write(dir.join("table.pdf"), &table);

    // 2b. Multi-page PDF — the regression fixture for the rasterizer. Four pages, three
    // distinct geometries, and a /Rotate 90 page: a renderer that only ever produces page
    // one (`sips`) or that ignores /Rotate fails this on the page count and the sizes
    // alone, without needing a model in the loop.
    let multipage = multipage_pdf();
    write(dir.join("multipage.pdf"), &multipage);

    // 3. Chart PNG — three labeled-by-color bars (no text; describable by shape/color).
    write_png(dir.join("chart.png"), bar_chart());
    // 4. Screenshot PNG — a UI-like mock: a title bar and two buttons.
    write_png(dir.join("screenshot.png"), screenshot_mock());
    // 5. Photo PNG — a smooth diagonal gradient (a stand-in "photo").
    write_png(dir.join("photo.png"), gradient_photo());

    println!("wrote 6 fixtures to {}", dir.display());
}

fn write(path: std::path::PathBuf, bytes: &[u8]) {
    let mut f = std::fs::File::create(&path).expect("create fixture");
    f.write_all(bytes).expect("write fixture");
    println!("  {} ({} bytes)", path.display(), bytes.len());
}

fn write_png(path: std::path::PathBuf, img: RgbImage) {
    img.save(&path).expect("save png");
    println!("  {} ({}x{})", path.display(), img.width(), img.height());
}

/// Emit a single-page US-Letter PDF drawing each `(x, y, size, text)` line in Helvetica,
/// with a correct cross-reference table (byte offsets computed as the buffer is built).
fn text_pdf(lines: &[(f32, f32, f32, &str)]) -> Vec<u8> {
    // Content stream: one BT…ET per line, absolute-positioned via Td from the origin.
    let mut content = String::new();
    for (x, y, size, text) in lines {
        content.push_str(&format!(
            "BT /F1 {size} Tf {x} {y} Td ({}) Tj ET\n",
            escape_pdf_text(text)
        ));
    }
    let content_bytes = content.into_bytes();

    let objects: [String; 5] = [
        "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_string(),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
         /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"
            .to_string(),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_string(),
        format!("<< /Length {} >>", content_bytes.len()),
    ];

    let mut buf: Vec<u8> = Vec::new();
    buf.extend_from_slice(b"%PDF-1.4\n");
    let mut offsets = [0usize; 5];
    for (i, body) in objects.iter().enumerate() {
        offsets[i] = buf.len();
        buf.extend_from_slice(format!("{} 0 obj\n{}\n", i + 1, body).as_bytes());
        if i == 4 {
            // Object 5 carries the content stream.
            buf.extend_from_slice(b"stream\n");
            buf.extend_from_slice(&content_bytes);
            buf.extend_from_slice(b"\nendstream\n");
        }
        buf.extend_from_slice(b"endobj\n");
    }
    // Cross-reference table: 20-byte entries (10-digit offset, space, 5-digit gen, " n \n").
    let xref_start = buf.len();
    buf.extend_from_slice(b"xref\n0 6\n0000000000 65535 f \n");
    for off in &offsets {
        buf.extend_from_slice(format!("{off:010} 00000 n \n").as_bytes());
    }
    buf.extend_from_slice(
        format!("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref_start}\n%%EOF\n").as_bytes(),
    );
    buf
}

/// Emit a FOUR-page PDF whose pages differ in size and rotation, each carrying its own
/// heading. Same hand-computed xref as [`text_pdf`]; object numbering is
/// `1` catalog, `2` page tree, `3` font, `4..` the page objects, then the content streams.
fn multipage_pdf() -> Vec<u8> {
    // (width, height, /Rotate, heading, second line)
    let pages: [(f32, f32, i32, &str, &str); 4] = [
        (
            612.0,
            792.0,
            0,
            "PAGE ONE OF FOUR - COVER",
            "Letter portrait. Reference: MP-2026-0001.",
        ),
        (
            595.0,
            842.0,
            0,
            "PAGE TWO OF FOUR - DETAIL",
            "A4 portrait. Amount carried forward: EUR 1240.00.",
        ),
        (
            792.0,
            612.0,
            0,
            "PAGE THREE OF FOUR - SUMMARY",
            "Letter landscape. Closing balance: EUR 2203.00.",
        ),
        (
            612.0,
            792.0,
            90,
            "PAGE FOUR OF FOUR - APPENDIX",
            "Letter portrait, rotated ninety degrees.",
        ),
    ];
    let n = pages.len();

    let mut bodies: Vec<String> = Vec::new();
    let mut streams: Vec<Vec<u8>> = Vec::new();
    bodies.push("<< /Type /Catalog /Pages 2 0 R >>".to_string());
    let kids = (0..n)
        .map(|i| format!("{} 0 R", 4 + i))
        .collect::<Vec<_>>()
        .join(" ");
    bodies.push(format!("<< /Type /Pages /Kids [{kids}] /Count {n} >>"));
    bodies.push("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_string());
    for (i, (w, h, rotate, _, _)) in pages.iter().enumerate() {
        bodies.push(format!(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {w} {h}] /Rotate {rotate} \
             /Resources << /Font << /F1 3 0 R >> >> /Contents {} 0 R >>",
            4 + n + i
        ));
    }
    for (_, h, _, heading, line) in pages.iter() {
        let content = format!(
            "BT /F1 22 Tf 72 {} Td ({}) Tj ET\nBT /F1 13 Tf 72 {} Td ({}) Tj ET\n",
            h - 90.0,
            escape_pdf_text(heading),
            h - 120.0,
            escape_pdf_text(line)
        );
        let bytes = content.into_bytes();
        bodies.push(format!("<< /Length {} >>", bytes.len()));
        streams.push(bytes);
    }

    let stream_first = bodies.len() - n;
    let mut buf: Vec<u8> = Vec::new();
    buf.extend_from_slice(b"%PDF-1.4\n");
    let mut offsets = Vec::with_capacity(bodies.len());
    for (i, body) in bodies.iter().enumerate() {
        offsets.push(buf.len());
        buf.extend_from_slice(format!("{} 0 obj\n{}\n", i + 1, body).as_bytes());
        if i >= stream_first {
            buf.extend_from_slice(b"stream\n");
            buf.extend_from_slice(&streams[i - stream_first]);
            buf.extend_from_slice(b"\nendstream\n");
        }
        buf.extend_from_slice(b"endobj\n");
    }
    let size = bodies.len() + 1;
    let xref_start = buf.len();
    buf.extend_from_slice(format!("xref\n0 {size}\n0000000000 65535 f \n").as_bytes());
    for off in &offsets {
        buf.extend_from_slice(format!("{off:010} 00000 n \n").as_bytes());
    }
    buf.extend_from_slice(
        format!("trailer\n<< /Size {size} /Root 1 0 R >>\nstartxref\n{xref_start}\n%%EOF\n")
            .as_bytes(),
    );
    buf
}

fn escape_pdf_text(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('(', "\\(")
        .replace(')', "\\)")
}

fn bar_chart() -> RgbImage {
    let (w, h) = (480u32, 320u32);
    let mut img: RgbImage = ImageBuffer::from_pixel(w, h, Rgb([255, 255, 255]));
    let bars = [
        (60u32, 200u32, Rgb([220, 60, 60])),  // red, tall
        (200u32, 120u32, Rgb([60, 160, 80])), // green, medium
        (340u32, 260u32, Rgb([70, 90, 200])), // blue, tallest
    ];
    let bar_w = 80u32;
    for (x0, bh, color) in bars {
        for x in x0..(x0 + bar_w).min(w) {
            for y in (h - bh)..h {
                img.put_pixel(x, y, color);
            }
        }
    }
    img
}

fn screenshot_mock() -> RgbImage {
    let (w, h) = (500u32, 360u32);
    let mut img: RgbImage = ImageBuffer::from_pixel(w, h, Rgb([245, 245, 248]));
    // Title bar.
    for x in 0..w {
        for y in 0..48 {
            img.put_pixel(x, y, Rgb([40, 44, 52]));
        }
    }
    // Two buttons.
    for (x0, color) in [(40u32, Rgb([80, 140, 240])), (200u32, Rgb([90, 200, 120]))] {
        for x in x0..(x0 + 120) {
            for y in 120..168 {
                img.put_pixel(x, y, color);
            }
        }
    }
    img
}

fn gradient_photo() -> RgbImage {
    let (w, h) = (400u32, 300u32);
    ImageBuffer::from_fn(w, h, |x, y| {
        let r = (x * 255 / w) as u8;
        let g = (y * 255 / h) as u8;
        let b = ((x + y) * 255 / (w + h)) as u8;
        Rgb([r, g, b])
    })
}
