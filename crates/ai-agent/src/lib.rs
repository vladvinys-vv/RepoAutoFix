use repoautofix_core::*;
use async_trait::async_trait;
use rig::{
    completion::{Prompt, Chat},
    providers::{anthropic, openai},
    client::CompletionClient,
};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::{info, debug, warn};

pub mod tools;
use tools::*;

#[derive(Debug, Clone)]
pub struct AiFixAgent {
    client: Box<dyn CompletionClient>,
    tools: Vec<Box<dyn AiTool>>,
    system_prompt: String,
    max_rounds: usize,
    temperature: f32,
}

impl AiFixAgent {
    pub fn new_anthropic(api_key: &str, model: &str) -> anyhow::Result<Self> {
        let client = anthropic::Client::new(api_key);
        let model = client.completion_model(model);
        
        Ok(Self {
            client: Box::new(model),
            tools: Self::default_tools(),
            system_prompt: Self::default_system_prompt(),
            max_rounds: 10,
            temperature: 0.1,
        })
    }

    pub fn new_openai(api_key: &str, model: &str) -> anyhow::Result<Self> {
        let client = openai::Client::new(api_key);
        let model = client.completion_model(model);
        
        Ok(Self {
            client: Box::new(model),
            tools: Self::default_tools(),
            system_prompt: Self::default_system_prompt(),
            max_rounds: 10,
            temperature: 0.1,
        })
    }

    fn default_tools() -> Vec<Box<dyn AiTool>> {
        vec![
            Box::new(ReadFileTool::new()),
            Box::new(EditFileTool::new()),
            Box::new(RunLintTool::new()),
            Box::new(RunTestsTool::new()),
            Box::new(SearchCodeTool::new()),
            Box::new(ViewDiffTool::new()),
        ]
    }

    fn default_system_prompt() -> String {
        r#"You are an expert code repair agent. Your task is to fix code issues identified by static analysis tools.

## Guidelines:
1. **Precision**: Make minimal, targeted fixes. Don't refactor unrelated code.
2. **Safety**: Preserve existing behavior. Run tests to verify.
3. **Context**: Use related files (tests, imports, similar patterns) to understand intent.
4. **Verification**: Always run the linter after your fix to confirm it's resolved.

## Tool Usage:
- `read_file`: Examine file content
- `edit_file`: Apply precise edits (use exact string matching)
- `run_lint`: Verify your fix resolves the diagnostic
- `run_tests`: Ensure no regressions
- `search_code`: Find similar patterns in codebase
- `view_diff`: Review your changes before finalizing

## Output Format:
When providing a fix, return ONLY the edited file content. No explanations, no markdown.

## Process:
1. Analyze the diagnostic and file context
2. Formulate a fix hypothesis
3. Apply the fix using edit_file
4. Run run_lint to verify
5. Run run_tests if available
6. If tests fail, iterate
7. Return final fixed content"#.to_string()
    }

    pub async fn fix_batch(&self, candidates: Vec<AiFixCandidate>) -> anyhow::Result<Vec<AiFixResult>> {
        let mut results = Vec::new();
        
        for candidate in candidates {
            let result = self.fix_single(candidate).await?;
            results.push(result);
        }
        
        Ok(results)
    }

    pub async fn fix_single(&self, candidate: AiFixCandidate) -> anyhow::Result<AiFixResult> {
        info!("AI fixing: {} in {}", candidate.context.diagnostic.code, candidate.context.file_path.display());
        
        let context = candidate.context;
        let mut messages = vec![
            rig::message::Message::system(&self.system_prompt),
            rig::message::Message::user(&context.to_prompt()),
        ];
        
        let mut edits = Vec::new();
        let mut tests_passed = None;
        let mut last_error = None;
        
        for round in 0..self.max_rounds {
            debug!("AI fix round {}", round + 1);
            
            // Build tool definitions for the model
            let tool_defs: Vec<_> = self.tools.iter().map(|t| t.definition()).collect();
            
            // Get response from model
            let response = self.client.chat(&messages, tool_defs).await?;
            
            if response.tool_calls.is_empty() {
                // Model provided final answer (should be fixed file content)
                let fixed_content = response.text;
                
                // Calculate diff
                let original = &context.file_content;
                if fixed_content != *original {
                    edits = self.compute_edits(original, &fixed_content, &context.diagnostic.range);
                }
                
                return Ok(AiFixResult {
                    candidate,
                    success: true,
                    edits,
                    explanation: "AI provided fixed content".to_string(),
                    tests_passed,
                    error: None,
                });
            }
            
            // Execute tool calls
            for tool_call in response.tool_calls {
                let tool = self.tools.iter().find(|t| t.name() == tool_call.name)
                    .ok_or_else(|| anyhow::anyhow!("Unknown tool: {}", tool_call.name))?;
                
                let result = tool.execute(tool_call.arguments).await?;
                messages.push(rig::message::Message::tool_result(tool_call.id, result));
            }
            
            messages.push(rig::message::Message::assistant(response.text));
        }
        
        Ok(AiFixResult {
            candidate,
            success: false,
            edits,
            explanation: format!("Max rounds ({}) exceeded", self.max_rounds),
            tests_passed,
            error: Some("Max rounds exceeded".to_string()),
        })
    }

    fn compute_edits(&self, original: &str, fixed: &str, range: &Range) -> Vec<TextEdit> {
        // Simplified: if content changed, create one edit for the diagnostic range
        // In practice, would use a proper diff algorithm
        if original != fixed {
            vec![TextEdit {
                range: range.clone(),
                new_text: fixed.to_string(),
            }]
        } else {
            Vec::new()
        }
    }
}

#[async_trait]
pub trait AiTool: Send + Sync {
    fn name(&self) -> &'static str;
    fn description(&self) -> &'static str;
    fn parameters_schema(&self) -> serde_json::Value;
    fn definition(&self) -> rig::tool::ToolDefinition {
        rig::tool::ToolDefinition {
            name: self.name().to_string(),
            description: self.description().to_string(),
            parameters: self.parameters_schema(),
        }
    }
    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<String>;
}

// Tool implementations
pub mod tools {
    use super::*;
    use std::process::Command;

    pub struct ReadFileTool;
    
    impl ReadFileTool {
        pub fn new() -> Self { Self }
    }
    
    #[async_trait]
    impl AiTool for ReadFileTool {
        fn name(&self) -> &'static str { "read_file" }
        fn description(&self) -> &'static str { "Read a file's content" }
        fn parameters_schema(&self) -> serde_json::Value {
            json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "File path to read" },
                    "offset": { "type": "integer", "description": "Line offset to start reading" },
                    "limit": { "type": "integer", "description": "Max lines to read" }
                },
                "required": ["path"]
            })
        }
        
        async fn execute(&self, args: serde_json::Value) -> anyhow::Result<String> {
            let path: PathBuf = serde_json::from_value(args.get("path").cloned().unwrap())?;
            let offset = args.get("offset").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
            let limit = args.get("limit").and_then(|v| v.as_u64()).unwrap_or(200) as usize;
            
            let content = std::fs::read_to_string(&path)?;
            let lines: Vec<_> = content.lines().collect();
            let end = (offset + limit).min(lines.len());
            let selected = lines[offset..end].join("\n");
            
            Ok(format!("File: {}\nLines {}-{}:\n{}", path.display(), offset + 1, end, selected))
        }
    }

    pub struct EditFileTool;
    
    impl EditFileTool {
        pub fn new() -> Self { Self }
    }
    
    #[async_trait]
    impl AiTool for EditFileTool {
        fn name(&self) -> &'static str { "edit_file" }
        fn description(&self) -> &'static str { "Apply a precise edit to a file using exact string replacement" }
        fn parameters_schema(&self) -> serde_json::Value {
            json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "File path to edit" },
                    "old_text": { "type": "string", "description": "Exact text to replace" },
                    "new_text": { "type": "string", "description": "New text to insert" }
                },
                "required": ["path", "old_text", "new_text"]
            })
        }
        
        async fn execute(&self, args: serde_json::Value) -> anyhow::Result<String> {
            let path: PathBuf = serde_json::from_value(args.get("path").cloned().unwrap())?;
            let old_text = args.get("old_text").and_then(|v| v.as_str()).unwrap_or("");
            let new_text = args.get("new_text").and_then(|v| v.as_str()).unwrap_or("");
            
            let content = std::fs::read_to_string(&path)?;
            
            if !content.contains(old_text) {
                return Err(anyhow::anyhow!("Old text not found in file"));
            }
            
            let new_content = content.replace(old_text, new_text);
            std::fs::write(&path, &new_content)?;
            
            Ok(format!("Successfully edited {}", path.display()))
        }
    }

    pub struct RunLintTool;
    
    impl RunLintTool {
        pub fn new() -> Self { Self }
    }
    
    #[async_trait]
    impl AiTool for RunLintTool {
        fn name(&self) -> &'static str { "run_lint" }
        fn description(&self) -> &'static str { "Run linter on a file to check for remaining issues" }
        fn parameters_schema(&self) -> serde_json::Value {
            json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "File or directory to lint" },
                    "language": { "type": "string", "description": "Language: rust, dart, typescript, python, go" }
                },
                "required": ["path", "language"]
            })
        }
        
        async fn execute(&self, args: serde_json::Value) -> anyhow::Result<String> {
            let path: PathBuf = serde_json::from_value(args.get("path").cloned().unwrap())?;
            let language = args.get("language").and_then(|v| v.as_str()).unwrap_or("");
            
            let output = match language {
                "rust" => Command::new("cargo").args(["clippy", "--message-format=json"]).current_dir(&path).output()?,
                "dart" => Command::new("dart").args(["analyze", "--format=json", path.to_str().unwrap()]).output()?,
                "typescript" => Command::new("npx").args(["eslint", "--format=json", path.to_str().unwrap()]).output()?,
                "python" => Command::new("ruff").args(["check", "--output-format=json", path.to_str().unwrap()]).output()?,
                "go" => Command::new("go").args(["vet", path.to_str().unwrap()]).output()?,
                _ => return Err(anyhow::anyhow!("Unknown language: {}", language)),
            };
            
            Ok(String::from_utf8_lossy(&output.stdout).to_string())
        }
    }

    pub struct RunTestsTool;
    
    impl RunTestsTool {
        pub fn new() -> Self { Self }
    }
    
    #[async_trait]
    impl AiTool for RunTestsTool {
        fn name(&self) -> &'static str { "run_tests" }
        fn description(&self) -> &'static str { "Run tests for the project or specific file" }
        fn parameters_schema(&self) -> serde_json::Value {
            json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Project root or test file" },
                    "language": { "type": "string", "description": "Language: rust, dart, typescript, python, go" },
                    "test_file": { "type": "string", "description": "Specific test file to run (optional)" }
                },
                "required": ["path", "language"]
            })
        }
        
        async fn execute(&self, args: serde_json::Value) -> anyhow::Result<String> {
            let path: PathBuf = serde_json::from_value(args.get("path").cloned().unwrap())?;
            let language = args.get("language").and_then(|v| v.as_str()).unwrap_or("");
            let test_file = args.get("test_file").and_then(|v| v.as_str());
            
            let output = match language {
                "rust" => {
                    let mut cmd = Command::new("cargo");
                    cmd.current_dir(&path).arg("test");
                    if let Some(tf) = test_file { cmd.arg("--test").arg(tf); }
                    cmd.output()?
                }
                "dart" => {
                    let mut cmd = Command::new("dart");
                    cmd.current_dir(&path).arg("test");
                    if let Some(tf) = test_file { cmd.arg(tf); }
                    cmd.output()?
                }
                "typescript" => {
                    let mut cmd = Command::new("npm");
                    cmd.current_dir(&path).arg("test");
                    if let Some(tf) = test_file { cmd.arg("--").arg(tf); }
                    cmd.output()?
                }
                "python" => {
                    let mut cmd = Command::new("pytest");
                    cmd.current_dir(&path);
                    if let Some(tf) = test_file { cmd.arg(tf); }
                    cmd.output()?
                }
                "go" => {
                    let mut cmd = Command::new("go");
                    cmd.current_dir(&path).arg("test");
                    if let Some(tf) = test_file { cmd.arg("-run").arg(tf); }
                    cmd.output()?
                }
                _ => return Err(anyhow::anyhow!("Unknown language: {}", language)),
            };
            
            let stdout = String::from_utf8_lossy(&output.stdout);
            let stderr = String::from_utf8_lossy(&output.stderr);
            
            Ok(format!("Exit code: {}\nStdout:\n{}\nStderr:\n{}", 
                output.status.code().unwrap_or(-1), stdout, stderr))
        }
    }

    pub struct SearchCodeTool;
    
    impl SearchCodeTool {
        pub fn new() -> Self { Self }
    }
    
    #[async_trait]
    impl AiTool for SearchCodeTool {
        fn name(&self) -> &'static str { "search_code" }
        fn description(&self) -> &'static str { "Search for code patterns in the codebase" }
        fn parameters_schema(&self) -> serde_json::Value {
            json!({
                "type": "object",
                "properties": {
                    "pattern": { "type": "string", "description": "Regex pattern to search for" },
                    "path": { "type": "string", "description": "Directory to search in" },
                    "file_pattern": { "type": "string", "description": "File pattern (e.g., *.rs, *.dart)" }
                },
                "required": ["pattern", "path"]
            })
        }
        
        async fn execute(&self, args: serde_json::Value) -> anyhow::Result<String> {
            let pattern = args.get("pattern").and_then(|v| v.as_str()).unwrap_or("");
            let path: PathBuf = serde_json::from_value(args.get("path").cloned().unwrap())?;
            let file_pattern = args.get("file_pattern").and_then(|v| v.as_str()).unwrap_or("*");
            
            // Use ripgrep if available, otherwise grep
            let output = if which::which("rg").is_ok() {
                Command::new("rg")
                    .args(["--json", pattern])
                    .arg(&path)
                    .output()?
            } else {
                Command::new("grep")
                    .args(["-r", "-n", pattern])
                    .arg(&path)
                    .output()?
            };
            
            Ok(String::from_utf8_lossy(&output.stdout).to_string())
        }
    }

    pub struct ViewDiffTool;
    
    impl ViewDiffTool {
        pub fn new() -> Self { Self }
    }
    
    #[async_trait]
    impl AiTool for ViewDiffTool {
        fn name(&self) -> &'static str { "view_diff" }
        fn description(&self) -> &'static str { "Show diff between original and modified file" }
        fn parameters_schema(&self) -> serde_json::Value {
            json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "File path" },
                    "original": { "type": "string", "description": "Original content" },
                    "modified": { "type": "string", "description": "Modified content" }
                },
                "required": ["path", "original", "modified"]
            })
        }
        
        async fn execute(&self, args: serde_json::Value) -> anyhow::Result<String> {
            let path: PathBuf = serde_json::from_value(args.get("path").cloned().unwrap())?;
            let original = args.get("original").and_then(|v| v.as_str()).unwrap_or("");
            let modified = args.get("modified").and_then(|v| v.as_str()).unwrap_or("");
            
            // Simple diff output
            let mut diff = String::new();
            diff.push_str(&format!("--- {}\n", path.display()));
            diff.push_str(&format!("+++ {}\n", path.display()));
            
            let orig_lines: Vec<_> = original.lines().collect();
            let mod_lines: Vec<_> = modified.lines().collect();
            
            // Very simple diff - just show changed lines
            for (i, (o, m)) in orig_lines.iter().zip(mod_lines.iter()).enumerate() {
                if o != m {
                    diff.push_str(&format!("-{}: {}\n", i + 1, o));
                    diff.push_str(&format!("+{}: {}\n", i + 1, m));
                }
            }
            
            Ok(diff)
        }
    }
}