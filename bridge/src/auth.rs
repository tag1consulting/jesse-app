use crate::*;

pub type ApiError = (StatusCode, String);

// ---- Core logic -----------------------------------------------------------

pub fn check_auth(headers: &HeaderMap, token: &str) -> Result<(), ApiError> {
    if token.is_empty() {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "Server misconfigured: JESSE_TOKEN not set".to_string(),
        ));
    }
    // Missing / non-UTF8 header → treat as empty → falls through to 401.
    let got = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    // The "Bearer " prefix is not secret; strip it with an ordinary
    // short-circuiting compare. Absent prefix → 401.
    let unauthorized = || (StatusCode::UNAUTHORIZED, "Unauthorized".to_string());
    let presented = got.strip_prefix("Bearer ").ok_or_else(unauthorized)?;
    // Compare only the secret token bytes in constant time. Token length is not
    // secret, so ct_eq returning false on a length mismatch is fine.
    if presented.as_bytes().ct_eq(token.as_bytes()).into() {
        Ok(())
    } else {
        Err(unauthorized())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn header_map(auth: Option<&str>) -> HeaderMap {
        let mut h = HeaderMap::new();
        if let Some(v) = auth {
            h.insert("authorization", v.parse().unwrap());
        }
        h
    }
    #[test]
    fn check_auth_empty_token_is_500() {
        let err = check_auth(&header_map(Some("Bearer anything")), "").unwrap_err();
        assert_eq!(err.0, StatusCode::INTERNAL_SERVER_ERROR);
    }
    #[test]
    fn check_auth_matching_bearer_ok() {
        assert!(check_auth(&header_map(Some("Bearer s3cret")), "s3cret").is_ok());
    }
    #[test]
    fn check_auth_wrong_token_is_401() {
        let err = check_auth(&header_map(Some("Bearer nope")), "s3cret").unwrap_err();
        assert_eq!(err.0, StatusCode::UNAUTHORIZED);
    }
    #[test]
    fn check_auth_missing_header_is_401() {
        let err = check_auth(&header_map(None), "s3cret").unwrap_err();
        assert_eq!(err.0, StatusCode::UNAUTHORIZED);
    }
    #[test]
    fn check_auth_token_without_bearer_prefix_is_401() {
        // Correct token value but no "Bearer " prefix → still rejected.
        let err = check_auth(&header_map(Some("s3cret")), "s3cret").unwrap_err();
        assert_eq!(err.0, StatusCode::UNAUTHORIZED);
    }
}
