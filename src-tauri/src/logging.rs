//! Timestamped, tagged dev logging. `log!` always prints; `debug!` only
//! when CO_SHEEP_DEBUG=1|true. Both write to stderr like the bare
//! eprintln!s they replace.

use std::borrow::Cow;
use std::sync::LazyLock;

pub static DEBUG: LazyLock<bool> = LazyLock::new(|| {
    matches!(
        std::env::var("CO_SHEEP_DEBUG").as_deref(),
        Ok("1") | Ok("true")
    )
});

macro_rules! log {
    ($tag:expr, $($arg:tt)*) => {
        eprintln!(
            "{} [{:<7}] {}",
            chrono::Local::now().format("%H:%M:%S"),
            $tag,
            format!($($arg)*)
        )
    };
}

macro_rules! debug {
    ($tag:expr, $($arg:tt)*) => {
        if *$crate::logging::DEBUG {
            log!($tag, $($arg)*);
        }
    };
}

/// Char-boundary-safe head truncation with ellipsis — logs are full of æ/ø/å.
pub fn truncate_for_log(s: &str, max_bytes: usize) -> Cow<'_, str> {
    if s.len() <= max_bytes {
        return Cow::Borrowed(s);
    }
    let mut end = max_bytes;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    Cow::Owned(format!("{}…", &s[..end]))
}

/// Raw model output for a log line: full at debug verbosity, else 200 bytes.
pub fn raw_for_log(s: &str) -> Cow<'_, str> {
    if *DEBUG {
        Cow::Borrowed(s)
    } else {
        truncate_for_log(s, 200)
    }
}

/// Strip one leading legacy "[co-sheep] " / "[co-sheep:id] " prefix — the
/// [web] tag already carries that information.
pub fn strip_legacy_prefix(message: &str) -> &str {
    if let Some(rest) = message.strip_prefix("[co-sheep") {
        if let Some((_, m)) = rest.split_once("] ") {
            return m;
        }
    }
    message
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_strings_pass_through_borrowed() {
        let s = "bæææ";
        assert!(matches!(truncate_for_log(s, 200), std::borrow::Cow::Borrowed(_)));
        assert_eq!(truncate_for_log(s, 200), "bæææ");
    }

    #[test]
    fn truncation_respects_char_boundaries_and_appends_ellipsis() {
        // 'æ' is 2 bytes; cutting at byte 5 would split the third 'æ'
        let s = "bæææ tenker"; // b(1) æ(2) æ(2) æ(2)...
        let t = truncate_for_log(s, 4);
        assert_eq!(t.as_ref(), "bæ…");
    }

    #[test]
    fn exact_fit_is_not_truncated() {
        let s = "abcd";
        assert_eq!(truncate_for_log(s, 4).as_ref(), "abcd");
    }

    #[test]
    fn strips_plain_and_id_legacy_prefixes() {
        assert_eq!(strip_legacy_prefix("[co-sheep] Canvas ready"), "Canvas ready");
        assert_eq!(strip_legacy_prefix("[co-sheep:friend_123] bounce"), "bounce");
        assert_eq!(strip_legacy_prefix("no prefix here"), "no prefix here");
        assert_eq!(strip_legacy_prefix("[other] tag"), "[other] tag");
    }
}
