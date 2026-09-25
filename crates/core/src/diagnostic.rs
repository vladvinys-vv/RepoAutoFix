use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum Severity {
    Error,
    Warning,
    Info,
    Hint,
}

impl Severity {
    pub fn from_str(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "error" => Severity::Error,
            "warning" | "warn" => Severity::Warning,
            "info" => Severity::Info,
            "hint" | "style" => Severity::Hint,
            _ => Severity::Warning,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Diagnostic {
    pub file: PathBuf,
    pub range: Range,
    pub severity: Severity,
    pub code: String,
    pub message: String,
    pub source: String,
    pub related_information: Vec<RelatedInformation>,
    pub tags: Vec<DiagnosticTag>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Range {
    pub start: Position,
    pub end: Position,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Position {
    pub line: usize,
    pub column: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelatedInformation {
    pub file: PathBuf,
    pub range: Range,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum DiagnosticTag {
    Unnecessary,
    Deprecated,
    Security,
    Performance,
    Style,
}

impl Diagnostic {
    pub fn new(
        file: PathBuf,
        range: Range,
        severity: Severity,
        code: String,
        message: String,
        source: String,
    ) -> Self {
        Self {
            file,
            range,
            severity,
            code,
            message,
            source,
            related_information: Vec::new(),
            tags: Vec::new(),
        }
    }

    pub fn with_tag(mut self, tag: DiagnosticTag) -> Self {
        self.tags.push(tag);
        self
    }

    pub fn with_related(mut self, info: RelatedInformation) -> Self {
        self.related_information.push(info);
        self
    }

    pub fn matches_pattern(&self, pattern: &str) -> bool {
        regex::Regex::new(pattern)
            .map(|re| re.is_match(&self.code) || re.is_match(&self.message))
            .unwrap_or(false)
    }
}