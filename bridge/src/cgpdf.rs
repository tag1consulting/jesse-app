//! **PDF page rendering through macOS's own PDF renderer** — the pixel half of
//! [`crate::vision::rasterize_pdf`].
//!
//! # Why the OS renderer and not a crate
//!
//! This used to be `pdfium-render`, chosen because it binds libpdfium at RUNTIME
//! (`dlopen`) rather than linking a C library at build time, which kept `cargo build`
//! and CI free of any native dependency. That reasoning was sound about the BUILD and
//! wrong about the DEPLOY: libpdfium is not installed on a stock Mac, so the runtime
//! bind failed and every PDF attachment came back as "pdfium library unavailable" unless
//! somebody installed a native library by hand and pointed `JESSE_PDFIUM_LIB` at it.
//! Nobody had. A renderer that ships with the operating system has no such step: Core
//! Graphics' PDF support is present on every Mac, at every version, with nothing to
//! install and no third-party crate in the graph.
//!
//! `sips(1)` is the obvious shell-out and is NOT usable here: it converts only the FIRST
//! page of a PDF and has no page-selection flag, so it silently drops pages 2..n. A
//! statement, a letter or a scanned form is routinely several pages, so first-page-only
//! is a data-loss bug wearing a simplification's clothes. `CGPDFDocument` addresses each
//! page by number, which is the property this layer actually needs.
//!
//! # What this is
//!
//! A direct FFI binding to the handful of `CGPDF*` / `CGBitmapContext*` entry points that
//! render one page into an RGBA buffer. The declarations are the whole unsafe surface:
//! every one is a documented, decades-stable C function, all of them take and return
//! opaque pointers plus POD structs, and the module owns every object it creates (each
//! `Create` is paired with its `Release` on both the success and the error path).
//!
//! macOS only, by construction. On any other target [`render_pdf_pages`] returns `Err`,
//! which is the same shape the pdfium-absent path returned and which both callers already
//! render as an attachment error rather than a panic or a silent drop. The bridge's CI
//! builds and tests on Linux, so this file has to compile there; only the FFI is gated.

// ---- The public shape -----------------------------------------------------

/// One rendered page: 8-bit RGBA pixels, top row first, tightly packed (`width * 4`
/// bytes per row — the renderer's own row padding is removed here so the caller can
/// hand the buffer straight to an encoder).
pub struct RenderedPage {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// Refuse to allocate a page bigger than this. A PDF declares its own page geometry, and
/// an attachment is untrusted input: a document claiming a 200-inch page would otherwise
/// turn a modest DPI into a multi-gigabyte bitmap. 40 MP is ~4x a 150-DPI A0 sheet, so no
/// real document reaches it and a hostile one gets an error string instead of the RAM.
#[cfg(target_os = "macos")]
const MAX_PAGE_PIXELS: u64 = 40_000_000;

/// Render pages `1..=min(page_cap, total)` of `pdf` at `dpi`, returning the pixels plus
/// the document's TRUE total page count (so the caller can report truncation honestly).
///
/// Blocking and synchronous; the caller runs it off the async runtime. Returns `Err` with
/// a human-readable reason for a PDF that will not open, a page that will not render, and
/// on any non-macOS target — never a panic.
pub fn render_pdf_pages(
    pdf: &[u8],
    dpi: u32,
    page_cap: usize,
) -> Result<(Vec<RenderedPage>, usize), String> {
    // Checked HERE rather than in the macOS half so that "there is nothing to render" reads
    // the same on every target: a caller (and a test) sees one message for empty input, not
    // one on macOS and the no-renderer message everywhere else.
    if pdf.is_empty() {
        return Err("the PDF is empty".to_string());
    }
    #[cfg(target_os = "macos")]
    {
        mac::render(pdf, dpi, page_cap)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (dpi, page_cap);
        Err(
            "PDF rendering needs macOS's Core Graphics; this bridge is not running on macOS"
                .to_string(),
        )
    }
}

// ---- The macOS implementation ---------------------------------------------

#[cfg(target_os = "macos")]
mod mac {
    use super::{RenderedPage, MAX_PAGE_PIXELS};
    use std::ffi::c_void;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGPoint {
        x: f64,
        y: f64,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGSize {
        width: f64,
        height: f64,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGRect {
        origin: CGPoint,
        size: CGSize,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGAffineTransform {
        a: f64,
        b: f64,
        c: f64,
        d: f64,
        tx: f64,
        ty: f64,
    }

    /// Every CG object here is an opaque, retain-counted pointer.
    type CgRef = *mut c_void;

    /// `kCGPDFCropBox` — the region a viewer displays. Falls back to the media box inside
    /// Core Graphics when a page declares no crop box, so this is the right ask for "what
    /// the reader would see", which is what a transcription helper needs.
    const K_CG_PDF_CROP_BOX: i32 = 1;

    /// `kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big` — 8 bits per component,
    /// RGBA in memory order. The page is painted onto opaque white first, so alpha is 255
    /// everywhere and premultiplied and straight alpha are the same bytes.
    const RGBA8_BITMAP_INFO: u32 = 1 | (4 << 12);

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGDataProviderCreateWithData(
            info: *mut c_void,
            data: *const c_void,
            size: usize,
            release_data: *const c_void,
        ) -> CgRef;
        fn CGDataProviderRelease(provider: CgRef);
        fn CGPDFDocumentCreateWithProvider(provider: CgRef) -> CgRef;
        fn CGPDFDocumentRelease(document: CgRef);
        fn CGPDFDocumentGetNumberOfPages(document: CgRef) -> usize;
        fn CGPDFDocumentIsUnlocked(document: CgRef) -> bool;
        fn CGPDFDocumentGetPage(document: CgRef, page_number: usize) -> CgRef;
        fn CGPDFPageGetBoxRect(page: CgRef, box_kind: i32) -> CGRect;
        fn CGPDFPageGetRotationAngle(page: CgRef) -> i32;
        fn CGPDFPageGetDrawingTransform(
            page: CgRef,
            box_kind: i32,
            rect: CGRect,
            rotate: i32,
            preserve_aspect_ratio: bool,
        ) -> CGAffineTransform;
        fn CGColorSpaceCreateDeviceRGB() -> CgRef;
        fn CGColorSpaceRelease(space: CgRef);
        fn CGBitmapContextCreate(
            data: *mut c_void,
            width: usize,
            height: usize,
            bits_per_component: usize,
            bytes_per_row: usize,
            space: CgRef,
            bitmap_info: u32,
        ) -> CgRef;
        fn CGBitmapContextGetData(context: CgRef) -> *mut c_void;
        fn CGBitmapContextGetBytesPerRow(context: CgRef) -> usize;
        fn CGContextRelease(context: CgRef);
        fn CGContextSetRGBFillColor(context: CgRef, red: f64, green: f64, blue: f64, alpha: f64);
        fn CGContextFillRect(context: CgRef, rect: CGRect);
        fn CGContextScaleCTM(context: CgRef, sx: f64, sy: f64);
        fn CGContextConcatCTM(context: CgRef, transform: CGAffineTransform);
        fn CGContextDrawPDFPage(context: CgRef, page: CgRef);
    }

    /// Open the document once, then render each wanted page. The per-page work lives in
    /// [`render_open_document`] rather than inline so that the document and its data
    /// provider are released on EVERY exit path: the rendering can fail out of the middle
    /// of the page loop, and there is exactly one place here that owns the cleanup.
    pub fn render(
        pdf: &[u8],
        dpi: u32,
        page_cap: usize,
    ) -> Result<(Vec<RenderedPage>, usize), String> {
        // SAFETY: the provider borrows `pdf`, which outlives every CG call below; the NULL
        // release callback is the documented way to say "the caller owns these bytes". Both
        // objects are released before this function returns, so nothing outlives the borrow.
        unsafe {
            let provider = CGDataProviderCreateWithData(
                std::ptr::null_mut(),
                pdf.as_ptr() as *const c_void,
                pdf.len(),
                std::ptr::null(),
            );
            if provider.is_null() {
                return Err("could not wrap the PDF bytes for the renderer".to_string());
            }
            let doc = CGPDFDocumentCreateWithProvider(provider);
            if doc.is_null() {
                CGDataProviderRelease(provider);
                return Err("could not open the PDF (it is not a readable PDF)".to_string());
            }
            let result = render_open_document(doc, dpi, page_cap);
            CGPDFDocumentRelease(doc);
            CGDataProviderRelease(provider);
            result
        }
    }

    /// # Safety
    /// `doc` must be a live `CGPDFDocumentRef`. Borrowed, never released here.
    unsafe fn render_open_document(
        doc: CgRef,
        dpi: u32,
        page_cap: usize,
    ) -> Result<(Vec<RenderedPage>, usize), String> {
        if !CGPDFDocumentIsUnlocked(doc) {
            return Err(
                "the PDF is password-protected, so its pages cannot be rendered".to_string(),
            );
        }
        let total_pages = CGPDFDocumentGetNumberOfPages(doc);
        if total_pages == 0 {
            // A zero-page document would otherwise reach the caller as "rendered nothing,
            // no error", which is exactly the silent drop this whole path exists to avoid.
            return Err("the PDF reports no pages (it may be malformed)".to_string());
        }
        let scale = (dpi as f64 / 72.0).max(0.1);
        let mut pages = Vec::with_capacity(total_pages.min(page_cap));
        for n in 1..=total_pages.min(page_cap) {
            pages.push(render_page(doc, n, scale)?);
        }
        Ok((pages, total_pages))
    }

    /// # Safety
    /// `doc` must be a live `CGPDFDocumentRef` and `n` a 1-based page number within it.
    unsafe fn render_page(doc: CgRef, n: usize, scale: f64) -> Result<RenderedPage, String> {
        let page = CGPDFDocumentGetPage(doc, n);
        if page.is_null() {
            return Err(format!("page {n} could not be read from the PDF"));
        }
        let box_rect = CGPDFPageGetBoxRect(page, K_CG_PDF_CROP_BOX);
        if !(box_rect.size.width.is_finite() && box_rect.size.height.is_finite())
            || box_rect.size.width <= 0.0
            || box_rect.size.height <= 0.0
        {
            return Err(format!("page {n} declares no usable page size"));
        }
        // A page carrying /Rotate 90 or 270 is DISPLAYED with its sides swapped, so the
        // output bitmap must be swapped too or the rotated content would be cropped to a
        // portrait frame. Core Graphics applies the rotation itself, below.
        let quarter_turned = CGPDFPageGetRotationAngle(page).rem_euclid(180) != 0;
        let (w_pts, h_pts) = if quarter_turned {
            (box_rect.size.height, box_rect.size.width)
        } else {
            (box_rect.size.width, box_rect.size.height)
        };
        let width = (w_pts * scale).round().max(1.0) as u64;
        let height = (h_pts * scale).round().max(1.0) as u64;
        if width.saturating_mul(height) > MAX_PAGE_PIXELS {
            return Err(format!(
                "page {n} would render to {width}x{height} pixels, past the {MAX_PAGE_PIXELS}-pixel \
                 ceiling — lower JESSE_VISION_PDF_DPI for this document"
            ));
        }
        let (width, height) = (width as usize, height as usize);

        let space = CGColorSpaceCreateDeviceRGB();
        if space.is_null() {
            return Err(format!("page {n}: no device RGB color space"));
        }
        // `data: NULL` lets Core Graphics own the pixel buffer (freed with the context) and
        // `bytes_per_row: 0` lets it pick its own row alignment, which is why the copy-out
        // below goes row by row rather than in one slice.
        let ctx = CGBitmapContextCreate(
            std::ptr::null_mut(),
            width,
            height,
            8,
            0,
            space,
            RGBA8_BITMAP_INFO,
        );
        CGColorSpaceRelease(space);
        if ctx.is_null() {
            return Err(format!(
                "page {n}: could not allocate a {width}x{height} bitmap"
            ));
        }

        let frame = CGRect {
            origin: CGPoint { x: 0.0, y: 0.0 },
            size: CGSize {
                width: width as f64,
                height: height as f64,
            },
        };
        // Paper, not transparency: a PDF paints no background, and a helper reading a page
        // with a transparent ground sees black-on-black once the PNG is flattened.
        CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
        CGContextFillRect(ctx, frame);

        // Scale to DPI FIRST, then ask Core Graphics for the box/rotation transform into a
        // rect that is exactly the page's own size in points. `CGPDFPageGetDrawingTransform`
        // only ever shrinks a page to fit and never enlarges it, so handing it the pixel
        // rect would silently render at 1:1 and centre the result in a blank bitmap; handing
        // it a rect it does not need to scale keeps its crop-box and /Rotate handling while
        // the DPI comes from the CTM.
        CGContextScaleCTM(ctx, scale, scale);
        let page_rect = CGRect {
            origin: CGPoint { x: 0.0, y: 0.0 },
            size: CGSize {
                width: width as f64 / scale,
                height: height as f64 / scale,
            },
        };
        let transform = CGPDFPageGetDrawingTransform(page, K_CG_PDF_CROP_BOX, page_rect, 0, true);
        CGContextConcatCTM(ctx, transform);
        CGContextDrawPDFPage(ctx, page);

        let data = CGBitmapContextGetData(ctx) as *const u8;
        if data.is_null() {
            CGContextRelease(ctx);
            return Err(format!("page {n}: the renderer produced no pixels"));
        }
        let bytes_per_row = CGBitmapContextGetBytesPerRow(ctx);
        let mut rgba = Vec::with_capacity(width * height * 4);
        for y in 0..height {
            // Row 0 of a bitmap context's buffer is the TOP row of the image (the drawing
            // origin is bottom-left, but the storage is top-down), which is also PNG's
            // order — so this is a straight copy, not a flip.
            rgba.extend_from_slice(std::slice::from_raw_parts(
                data.add(y * bytes_per_row),
                width * 4,
            ));
        }
        CGContextRelease(ctx);
        Ok(RenderedPage {
            width: width as u32,
            height: height as u32,
            rgba,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `RenderedPage` deliberately has no `Debug` (it holds the pixels), so failures are
    /// read out by hand rather than through `unwrap_err`.
    fn reason(r: Result<(Vec<RenderedPage>, usize), String>) -> String {
        match r {
            Ok((pages, total)) => panic!("expected a refusal, rendered {} of {total}", pages.len()),
            Err(e) => e,
        }
    }

    #[test]
    fn empty_input_is_an_error_not_a_panic() {
        assert!(reason(render_pdf_pages(b"", 150, 4)).contains("empty"));
    }

    #[test]
    fn garbage_is_an_error_not_a_panic() {
        assert!(
            !reason(render_pdf_pages(b"this is not a PDF at all", 150, 4)).is_empty(),
            "a failure carries a reason"
        );
    }

    /// A truncated PDF header is the shape the attachment tests stage, and it must fail
    /// with a reason rather than rendering a blank page.
    #[test]
    fn a_truncated_pdf_is_an_error() {
        assert!(!reason(render_pdf_pages(
            b"%PDF-1.7\n%\xE2\xE3\xCF\xD3\n1 0 obj\n",
            150,
            4
        ))
        .is_empty());
    }
}
