use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use crate::Diagnostic;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiFixContext {
    pub diagnostic: Diagnostic,
    pub file_content: String,
    pub file_path: PathBuf,
    pub related_files: Vec<RelatedFile>,
    pub project_context: ProjectContext,
    pub suggested_fix: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelatedFile {
    pub path: PathBuf,
    pub content: String,
    pub reason: String, // e.g., "imports", "tests", "similar_pattern"
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectContext {
    pub language: String,
    pub config: serde_json::Value, // language-specific config (Cargo.toml, pubspec.yaml, etc.)
    pub dependencies: Vec<String>,
    pub test_files: Vec<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiFixCandidate {
    pub context: AiFixContext,
    pub priority: FixPriority,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub enum FixPriority {
    Critical,  // Security, data loss
    High,      // Crash bugs, logic errors
    Medium,    // Performance, maintainability
    Low,       // Style, minor warnings
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiFixResult {
    pub candidate: AiFixCandidate,
    pub success: bool,
    pub edits: Vec<crate::TextEdit>,
    pub explanation: String,
    pub tests_passed: Option<bool>,
    pub error: Option<String>,
}

impl AiFixContext {
    pub fn to_prompt(&self) -> String {
        let mut prompt = String::new();
        
        prompt.push_str(&format!("## Fix Request\n\n"));
        prompt.push_str(&format!("**File**: `{}`\n", self.file_path.display()));
        prompt.push_str(&format!("**Diagnostic**: `{}` - {}\n", self.diagnostic.code, self.diagnostic.message));
        prompt.push_str(&format!("**Severity**: {:?}\n", self.diagnostic.severity));
        prompt.push_str(&format!("**Location**: Line {}, Col {}\n\n", 
            self.diagnostic.range.start.line, self.diagnostic.range.start.column));
        
        prompt.push_str("## File Content\n\n");
        prompt.push_str(&format!("```{}\n{}\n```\n\n", self.project_context.language, self.file_content));
        
        if !self.related_files.is_empty() {
            prompt.push_str("## Related Files\n\n");
            for rel in &self.related_files {
                prompt.push_str(&format!("### `{}` ({})\n", rel.path.display(), rel.reason));
                prompt.push_str(&format!("```{}\n{}\n```\n\n", self.project_context.language, rel.content));
            }
        }
        
        if let Some(suggested) = &self.suggested_fix {
            prompt.push_str(&format!("## Suggested Fix\n\n{}\n\n", suggested));
        }
        
        prompt.push_str("## Task\n\n");
        prompt.push_str("Provide a precise fix for the diagnostic above. ");
        prompt.push_str("Return ONLY the edited file content with the fix applied. ");
        prompt.push_str("Do not include explanations or markdown formatting.\n");
        
        prompt
    }
}