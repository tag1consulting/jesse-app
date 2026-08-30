//! **The scope** — who a turn is acting for, carried out-of-band from the model.
//!
//! THE RULE THIS MODULE EXISTS TO ENFORCE: a tenant, a user or a workspace is something
//! the CALLER knows and the model is never asked. [`Scope`] is constructed once per turn
//! by whoever authenticated the request and passed by reference into every
//! [`Tool::call`](crate::tools::Tool::call); no tool ever reads one out of the argument
//! object the model generated.
//!
//! WHY A TYPE RATHER THAN A CONVENTION. A convention ("don't put a tenant in a schema")
//! is a thing a reviewer has to notice. The type makes the safe path the only ergonomic
//! one — a tool already HAS the scope as a parameter, so reading one from `args` is extra
//! work with no motivation — and [`check_schema_for_scope_arguments`] turns the unsafe
//! path into a build-time refusal rather than a review comment.
//!
//! In Phase 1 the bridge constructs a single fixed scope, so nothing here is yet load
//! bearing at runtime. It is defined at the boundary from the first commit anyway,
//! because the alternative — threading a tenant through a hundred call sites once a
//! second tenant exists — is the change nobody makes correctly.

use std::fmt;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Argument names a tool schema may NOT declare, in any casing, at any depth.
///
/// These are the names a model would plausibly emit if it believed it could choose whom
/// it was acting for. A tool that accepted one would be taking an authorization decision
/// from generated text, which is the single failure this whole layer is arranged to make
/// impossible.
pub const RESERVED_ARGUMENT_NAMES: &[&str] = &[
    "tenant",
    "tenant_id",
    "user",
    "user_id",
    "workspace",
    "workspace_id",
];

macro_rules! opaque_id {
    ($name:ident, $what:literal) => {
        #[doc = concat!("An opaque ", $what, " identifier.")]
        ///
        /// A newtype over a `String` with NO parsing and NO validation, deliberately. The
        /// identifiers come from whatever authenticated the caller — today a fixed literal,
        /// tomorrow a directory's subject id — and a crate that imposed a shape on them
        /// would have to be edited every time an identity provider disagreed with it. What
        /// the newtype buys is that a tenant cannot be passed where a user is expected,
        /// which is the mistake worth catching.
        #[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
        pub struct $name(String);

        impl $name {
            pub fn new(s: impl Into<String>) -> Self {
                $name(s.into())
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }
    };
}

opaque_id!(TenantId, "tenant");
opaque_id!(UserId, "user");
opaque_id!(WorkspaceId, "workspace");

/// Whom this turn is acting for. Constructed once per turn by the caller and passed by
/// reference into every tool call.
///
/// `Clone` because the loop hands a copy to its own bookkeeping (the usage record carries
/// the three ids), but note that cloning a scope never WIDENS one: there is no method
/// here that produces a scope for a different tenant, so a tool holding a `&Scope` can
/// only ever act inside the one it was given.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Scope {
    pub tenant: TenantId,
    pub user: UserId,
    pub workspace: WorkspaceId,
}

impl Scope {
    pub fn new(
        tenant: impl Into<String>,
        user: impl Into<String>,
        workspace: impl Into<String>,
    ) -> Self {
        Scope {
            tenant: TenantId::new(tenant),
            user: UserId::new(user),
            workspace: WorkspaceId::new(workspace),
        }
    }
}

/// A tool schema declared an argument the model must never be able to supply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopeShapedArgument {
    /// The offending property name, as the schema spelled it.
    pub argument: String,
}

impl fmt::Display for ScopeShapedArgument {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "schema declares the argument {:?}, which names part of the scope; \
             scope is passed to a tool by the caller and is never read from arguments",
            self.argument
        )
    }
}

impl std::error::Error for ScopeShapedArgument {}

/// Refuse a JSON Schema that declares a scope-shaped argument.
///
/// CALLED AT MANIFEST-BUILD TIME (see [`ToolSetBuilder::build`](crate::tools::ToolSetBuilder::build)),
/// not at call time. A runtime check would refuse the call AFTER the model had already
/// been shown a tool that invites it to name a tenant — the model would keep trying, the
/// turn would keep failing, and the operator would read it as a flaky tool. Refusing to
/// BUILD the set means such a tool cannot reach a manifest at all, so the invitation is
/// never issued.
///
/// The scan is RECURSIVE over every `properties` object in the schema, not just the top
/// level. `{"filter": {"properties": {"tenant_id": …}}}` is exactly as dangerous as a
/// top-level `tenant_id` and is the form somebody would reach for after a top-level-only
/// check refused the obvious spelling. Matching is ASCII-case-insensitive for the same
/// reason: `Tenant_Id` is not a different argument.
pub fn check_schema_for_scope_arguments(schema: &Value) -> Result<(), ScopeShapedArgument> {
    fn is_reserved(name: &str) -> bool {
        RESERVED_ARGUMENT_NAMES
            .iter()
            .any(|r| r.eq_ignore_ascii_case(name))
    }
    fn walk(v: &Value) -> Result<(), ScopeShapedArgument> {
        match v {
            Value::Object(map) => {
                if let Some(Value::Object(props)) = map.get("properties") {
                    for name in props.keys() {
                        if is_reserved(name) {
                            return Err(ScopeShapedArgument {
                                argument: name.clone(),
                            });
                        }
                    }
                }
                for child in map.values() {
                    walk(child)?;
                }
                Ok(())
            }
            Value::Array(items) => items.iter().try_for_each(walk),
            _ => Ok(()),
        }
    }
    walk(schema)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_clean_schema_passes() {
        let schema = json!({
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "max_bytes": {"type": "integer"}
            },
            "required": ["path"]
        });
        assert!(check_schema_for_scope_arguments(&schema).is_ok());
    }

    #[test]
    fn every_reserved_name_is_refused_at_the_top_level() {
        for name in RESERVED_ARGUMENT_NAMES {
            let schema = json!({"type": "object", "properties": {(*name): {"type": "string"}}});
            let err = check_schema_for_scope_arguments(&schema)
                .expect_err("{name} must be refused")
                .argument;
            assert_eq!(&err, name);
        }
    }

    #[test]
    fn casing_does_not_smuggle_one_through() {
        let schema = json!({"type": "object", "properties": {"Tenant_ID": {"type": "string"}}});
        assert!(check_schema_for_scope_arguments(&schema).is_err());
    }

    #[test]
    fn a_nested_schema_is_scanned_too() {
        // The form somebody reaches for after the top-level spelling is refused.
        let schema = json!({
            "type": "object",
            "properties": {
                "filter": {
                    "type": "object",
                    "properties": {"workspace_id": {"type": "string"}}
                }
            }
        });
        assert_eq!(
            check_schema_for_scope_arguments(&schema)
                .unwrap_err()
                .argument,
            "workspace_id"
        );
    }

    #[test]
    fn a_reserved_word_used_as_a_description_is_not_an_argument() {
        // Only PROPERTY NAMES are refused. A tool whose description mentions the word
        // "user" is ordinary English, and refusing it would make the check unusable.
        let schema = json!({
            "type": "object",
            "properties": {"note": {"type": "string", "description": "about the user"}}
        });
        assert!(check_schema_for_scope_arguments(&schema).is_ok());
    }

    #[test]
    fn the_ids_are_distinct_types() {
        let s = Scope::new("t1", "u1", "w1");
        assert_eq!(s.tenant.as_str(), "t1");
        assert_eq!(s.user.to_string(), "u1");
        assert_eq!(s.workspace, WorkspaceId::new("w1"));
    }
}
