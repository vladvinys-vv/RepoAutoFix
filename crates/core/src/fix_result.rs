use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use crate::Diagnostic;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FixResult {
    pub applied: Vec<AppliedFix>,
    pub failed: Vec<FailedFix>,
    pub skipped: Vec<SkippedFix>,
    pub remaining_diagnostics: Vec<Diagnostic>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppliedFix {
    pub file: PathBuf,
    pub diagnostic_code: String,
    pub edit: TextEdit,
    pub before: String,
    pub after: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FailedFix {
    pub file: PathBuf,
    pub diagnostic_code: String,
    pub error: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkippedFix {
    pub file: PathBuf,
    pub diagnostic_code: String,
    pub reason: SkipReason,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum SkipReason {
    PolicyDenied,
    RequiresReview,
    RequiresAi,
    NoFixAvailable,
    SafetyLimitExceeded,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TextEdit {
    pub range: crate::Range,
    pub new_text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FormatResult {
    pub files_changed: usize,
    pub files_formatted: Vec<PathBuf>,
    pub errors: Vec<FormatError>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FormatError {
    pub file: PathBuf,
    pub error: String,
}

impl FixResult {
    pub fn new() -> Self {
        Self {
            applied: Vec::new(),
            failed: Vec::new(),
            skipped: Vec::new(),
            remaining_diagnostics: Vec::new(),
        }
    }

    pub fn total_applied(&self) -> usize {
        self.applied.len()
    }

    pub fn total_failed(&self) -> usize {
        self.failed.len()
    }

    pub fn has_changes(&self) -> bool {
        !self.applied.is_empty()
    }
}

impl Default for FixResult {
    fn default() -> Self {
        Self::new()
    }
}